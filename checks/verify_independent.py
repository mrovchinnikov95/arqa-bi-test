#!/usr/bin/env python3
"""Независимый второй расчёт витрин кредитного портфеля.

Пересчитывает все выгрузки заново из сырых data/portfolio.csv и data/fx.csv
(pandas — загрузка и группировки, decimal.Decimal — вся арифметика с деньгами)
и сверяет с тем, что выгрузил SQL: dashboard/data/*.json и .tmp/export/v_loans.json.
Логика взята из спецификации задания, а не из SQL: каталог sql/ здесь не читается.

Запуск из корня репозитория:
    python3 checks/verify_independent.py
    python3 checks/verify_independent.py --self-test

Код возврата 1: есть расхождение, нет файла или строки, лишняя строка,
ошибка исходных данных, а в режиме --self-test — не пойманная порча.
"""
import argparse
import copy
import json
import sys
from datetime import date
from decimal import ROUND_HALF_UP, Decimal, getcontext
from pathlib import Path

import pandas as pd

getcontext().prec = 50

ROOT = Path(__file__).resolve().parent.parent
COLS = ['report_date', 'loan_id', 'borrower_id', 'group_id', 'sector', 'program',
        'currency', 'issue_date', 'maturity_date', 'principal_outstanding',
        'days_past_due', 'restructured', 'written_off']

MINUS = '−'   # знак минуса в подписях
TENGE = '₸'
DASH = '–'    # тире в метках классов и корзин

S_OK = 'Без просрочки'
S_1_30 = f'Просрочка 1{DASH}30'
S_31_90 = f'Просрочка 31{DASH}90'
S_90 = 'NPL: просрочка 90+'
S_RESTR = 'NPL: реструктуризация'
S_WO = 'Списан'
S_NONE = 'Нет в срезе'
STATE_ORDER = {S_OK: 1, S_1_30: 2, S_31_90: 3, S_90: 4, S_RESTR: 5, S_WO: 6, S_NONE: 7}

RATE_NPL, RATE_PAR30, RATE_STD = Decimal('0.50'), Decimal('0.10'), Decimal('0.01')
BN = Decimal(10) ** 9
HUNDRED = Decimal(100)
ZERO = Decimal(0)

DIMENSIONS = ['sector', 'program', 'currency', 'risk_class']

# Допуски: суммы, количества, строки, флаги — точно; доли — 1e-15; п.п. — 1e-13
TOL = {'exact': None, 'share': Decimal('1e-15'), 'pp': Decimal('1e-13')}

# Тип значения value у фактов комитета (остальные — точное равенство)
FACT_KIND = {code: 'pp' for code in ('npl_chg_pp', 'roll_npl_pp', 'reversal_npl_pp')}
FACT_KIND.update({code: 'share' for code in (
    'npl_prev', 'npl_curr', 'npl_if_not_cured', 'new_par30_group_share', 'sector_par30_prev', 'sector_par30_curr',
    'top10_par30_prev', 'top10_par30_curr', 'par30_prev', 'par30_curr', 'sector_par30_without_loan', 'restr_share',
    'restr_share_of_npl', 'restr_share_of_prov', 'matured_share', 'matured_not_restr_share', 'dup_share',
    'npl_if_irreversible')})

# Ключи строк каждой выгрузки
KEYS = {
    'v_risk_metrics.json': ('report_date',),
    'v_risk_metrics_long.json': ('report_date', 'metric_code'),
    'v_risk_by_dimension.json': ('report_date', 'dimension', 'dimension_value'),
    'v_top_groups.json': ('report_date', 'group_rank'),
    'v_portfolio_bridge.json': ('report_date', 'step_order'),
    'v_dpd_migration.json': ('report_date', 'from_state', 'to_state'),
    'v_data_quality.json': ('report_date', 'check_code'),
    'v_committee_facts.json': ('fact_code',),
    'v_loans.json': ('report_date', 'loan_id'),
}


# ---------- форматирование подписей ----------

def _round(x, d):
    return Decimal(x).quantize(Decimal(1).scaleb(-d), rounding=ROUND_HALF_UP)


def fmt_num(x, d):
    r = _round(x, d)
    sign = MINUS if r < 0 else ''
    whole, _, frac = f'{abs(r):f}'.partition('.')
    groups = []
    while len(whole) > 3:
        groups.insert(0, whole[-3:])
        whole = whole[:-3]
    groups.insert(0, whole)
    out = ' '.join(groups)
    if d > 0:
        out += ',' + frac
    return sign + out


def fmt_signed(x, d):
    return ('+' if _round(x, d) > 0 else '') + fmt_num(x, d)


def fmt_bn(x):
    return fmt_num(x / BN, 1) + f' млрд {TENGE}'


def fmt_bn_signed(x):
    return fmt_signed(x / BN, 1) + f' млрд {TENGE}'


def fmt_pct(s, d):
    return fmt_num(s * HUNDRED, d) + '%'


def fmt_pct_signed(s, d):
    return fmt_signed(s * HUNDRED, d) + '%'


def fmt_pp(p):
    return fmt_signed(p, 2) + ' п.п.'


# ---------- арифметика ----------

def dsum(values):
    """Сумма Decimal; пустая сумма = 0."""
    return sum((v for v in values if v is not None), ZERO)


def div(a, b):
    return None if b is None or b == 0 or a is None else a / b


# ---------- загрузка и очистка ----------

def load_loans(problems):
    """Читает сырые CSV, схлопывает полные дубли, считает курс и производные поля."""
    raw = pd.read_csv(ROOT / 'data' / 'portfolio.csv', dtype=str, keep_default_na=False)
    if list(raw.columns) != COLS:
        raise SystemExit(f'portfolio.csv: неожиданные колонки {list(raw.columns)}')
    fx_raw = pd.read_csv(ROOT / 'data' / 'fx.csv', dtype=str, keep_default_na=False)
    fx = {}
    for r in fx_raw.itertuples(index=False):
        key, rate = (r.date, r.currency), Decimal(r.rate_kzt)
        if key in fx and fx[key] != rate:
            problems.append(f'fx.csv: два разных курса на {key}')
        fx[key] = rate

    # Типизируем до сравнения дублей: 100.0 и 100.00 — одна и та же строка
    typed = raw.copy()
    typed['principal_outstanding'] = raw['principal_outstanding'].map(Decimal)
    for c in ('days_past_due', 'restructured', 'written_off'):
        typed[c] = raw[c].map(int).astype(object)
    typed['line'] = range(1, len(raw) + 1)   # 1 = первая строка после заголовка
    clean = typed.groupby(COLS, sort=False)['line'].agg(list).reset_index()

    # Разные версии одного кредита на одну дату — ошибка данных
    versions = clean.groupby(['report_date', 'loan_id']).size()
    conflicts = {d: int((versions.xs(d, level=0) > 1).sum())
                 for d in versions.index.get_level_values(0).unique()}
    for d, n in conflicts.items():
        if n:
            problems.append(f'portfolio.csv: {n} ключей ({d}, loan_id) с разными версиями')

    loans = []
    for r in clean.to_dict('records'):
        d, cur = r['report_date'], r['currency']
        principal = r['principal_outstanding']
        dpd, restr, wo = int(r['days_past_due']), int(r['restructured']), int(r['written_off'])
        if restr not in (0, 1) or wo not in (0, 1):
            problems.append(f'portfolio.csv: флаги не 0/1 у {d} {r["loan_id"]}')
        rate = Decimal(1) if cur == 'KZT' else fx.get((d, cur))
        if rate is None:
            problems.append(f'нет курса {cur} на {d} для {r["loan_id"]}')
        amount = principal * rate if rate is not None else None
        is_npl = dpd > 90 or restr == 1
        if dpd > 90:
            risk_class = S_90
        elif restr == 1:
            risk_class = S_RESTR
        elif dpd > 30:
            risk_class = S_31_90
        elif dpd > 0:
            risk_class = S_1_30
        else:
            risk_class = S_OK
        bucket = '0' if dpd == 0 else f'1{DASH}30' if dpd <= 30 else f'31{DASH}90' if dpd <= 90 else '91+'
        if wo == 1:
            prov_rate = None
        elif is_npl:
            prov_rate = RATE_NPL
        elif dpd > 30:
            prov_rate = RATE_PAR30
        else:
            prov_rate = RATE_STD
        lines = sorted(int(x) for x in r['line'])
        loans.append({
            'report_date': d, 'loan_id': r['loan_id'], 'borrower_id': r['borrower_id'],
            'group_id': r['group_id'], 'sector': r['sector'], 'program': r['program'],
            'currency': cur, 'issue_date': r['issue_date'], 'maturity_date': r['maturity_date'],
            'principal_outstanding': principal, 'fx_rate_kzt': rate, 'amount_kzt': amount,
            'days_past_due': dpd, 'dpd_bucket': bucket,
            'is_restructured': restr == 1, 'is_written_off': wo == 1, 'in_portfolio': wo == 0,
            'is_par30': dpd > 30, 'is_par90': dpd > 90, 'is_npl': is_npl,
            'risk_class': risk_class, 'provision_rate': prov_rate,
            'provision_kzt': amount * prov_rate if prov_rate is not None and amount is not None else None,
            'is_past_maturity': r['maturity_date'] < d,
            'source_rows': len(lines), 'source_lines': lines,
        })
    return loans, conflicts


def state_of(rec):
    """Состояние кредита для миграции; rec = None — кредита нет в срезе."""
    if rec is None:
        return S_NONE
    return S_WO if rec['is_written_off'] else rec['risk_class']


# ---------- расчёт всех выгрузок ----------

def agg(g):
    a = g['amount_kzt']
    return {
        'loan_count': len(g),
        'portfolio_kzt': dsum(a),
        'par30_kzt': dsum(a[g['is_par30']]),
        'par90_kzt': dsum(a[g['is_par90']]),
        'npl_kzt': dsum(a[g['is_npl']]),
        'restructured_kzt': dsum(a[g['is_restructured']]),
        'provisions_kzt': dsum(g['provision_kzt']),
    }


def ranked_groups(port):
    """Группы по сумме портфеля: по убыванию, при равенстве group_id по возрастанию."""
    sums = {gid: dsum(g['amount_kzt']) for gid, g in port.groupby('group_id')}
    return sorted(sums.items(), key=lambda kv: (-kv[1], kv[0]))


def build_expected(problems):
    loans, conflicts = load_loans(problems)
    L = pd.DataFrame(loans)
    dates = sorted(str(d) for d in L['report_date'].unique())
    by_date = {d: {} for d in dates}
    for rec in loans:
        by_date[rec['report_date']][rec['loan_id']] = rec
    port_of = {d: L[(L['report_date'] == d) & L['in_portfolio']] for d in dates}
    prev_of = {d: (dates[i - 1] if i else None) for i, d in enumerate(dates)}

    # 1) v_risk_metrics
    M, ranks = {}, {}
    for d in dates:
        port = port_of[d]
        m = agg(port)
        pf = m['portfolio_kzt']
        ranks[d] = ranked_groups(port)
        top10 = dsum(v for _, v in ranks[d][:10])
        wo = L[(L['report_date'] == d) & L['is_written_off']]
        M[d] = {
            'report_date': d, 'loan_count': m['loan_count'], 'portfolio_kzt': pf,
            'par30_kzt': m['par30_kzt'], 'par30_share': div(m['par30_kzt'], pf),
            'par90_kzt': m['par90_kzt'], 'par90_share': div(m['par90_kzt'], pf),
            'npl_kzt': m['npl_kzt'], 'npl_share': div(m['npl_kzt'], pf),
            'restructured_kzt': m['restructured_kzt'],
            'restructured_share': div(m['restructured_kzt'], pf),
            'provisions_kzt': m['provisions_kzt'], 'provisions_share': div(m['provisions_kzt'], pf),
            'top10_groups_kzt': top10, 'top10_share': div(top10, pf),
            'written_off_count': len(wo), 'written_off_kzt': dsum(wo['amount_kzt']),
        }
    risk_metrics = []
    for d in dates:
        m, p = M[d], M.get(prev_of[d])
        row = dict(m, prev_report_date=prev_of[d])
        row.update({k: None for k in ('portfolio_chg_kzt', 'portfolio_chg_rel', 'loan_count_chg',
                                      'par30_chg_pp', 'par90_chg_pp', 'npl_chg_pp', 'top10_chg_pp',
                                      'provisions_chg_kzt', 'provisions_chg_rel')})
        if p:
            row.update({
                'portfolio_chg_kzt': m['portfolio_kzt'] - p['portfolio_kzt'],
                'portfolio_chg_rel': div(m['portfolio_kzt'], p['portfolio_kzt']) - 1,
                'loan_count_chg': m['loan_count'] - p['loan_count'],
                'par30_chg_pp': (m['par30_share'] - p['par30_share']) * HUNDRED,
                'par90_chg_pp': (m['par90_share'] - p['par90_share']) * HUNDRED,
                'npl_chg_pp': (m['npl_share'] - p['npl_share']) * HUNDRED,
                'top10_chg_pp': (m['top10_share'] - p['top10_share']) * HUNDRED,
                'provisions_chg_kzt': m['provisions_kzt'] - p['provisions_kzt'],
                'provisions_chg_rel': div(m['provisions_kzt'], p['provisions_kzt']) - 1,
            })
        risk_metrics.append(row)

    # 2) v_risk_metrics_long
    metric_defs = [(1, 'portfolio', 'Портфель', 'kzt', 'portfolio_kzt'),
                   (2, 'par30', 'PAR30', 'share', 'par30_share'),
                   (3, 'par90', 'PAR90', 'share', 'par90_share'),
                   (4, 'npl', 'NPL', 'share', 'npl_share'),
                   (5, 'provisions', 'Провизии', 'kzt', 'provisions_kzt'),
                   (6, 'top10', 'Топ-10 групп', 'share', 'top10_share'),
                   (7, 'loans', 'Кредитов', 'count', 'loan_count')]
    long_rows = []
    for d in dates:
        for order, code, label, unit, src in metric_defs:
            v = M[d][src]
            pv = M[prev_of[d]][src] if prev_of[d] else None
            delta = v - pv if pv is not None else None
            rel = div(v, pv) - 1 if pv is not None and unit == 'kzt' else None
            change_display = None
            if delta is not None:
                if unit == 'kzt':
                    change_display = f'{fmt_bn_signed(delta)} ({fmt_pct_signed(rel, 1)})'
                elif unit == 'share':
                    change_display = fmt_pp(delta * HUNDRED)
                else:
                    change_display = fmt_signed(delta, 0)
            long_rows.append({
                'report_date': d, 'metric_code': code, 'prev_report_date': prev_of[d],
                'sort_order': order, 'metric_label': label, 'unit': unit,
                'value': v, 'prev_value': pv, 'change_abs': delta, 'change_rel': rel,
                'change_pp': delta * HUNDRED if delta is not None and unit == 'share' else None,
                'value_display': (fmt_bn(v) if unit == 'kzt' else
                                  fmt_pct(v, 2) if unit == 'share' else fmt_num(v, 0)),
                'change_display': change_display,
                'value_exact_display': f'{fmt_num(v, 2)} {TENGE}' if unit == 'kzt' else None,
            })

    # 3) v_risk_by_dimension; предыдущая строка — последняя более ранняя дата того же значения
    dim_rows, last_seen, dim_index = [], {}, {}
    for d in dates:
        port, pf = port_of[d], M[d]['portfolio_kzt']
        for dim in DIMENSIONS:
            for value, g in port.groupby(dim):
                a = agg(g)
                row = {
                    'report_date': d, 'dimension': dim, 'dimension_value': value,
                    'loan_count': a['loan_count'], 'portfolio_kzt': a['portfolio_kzt'],
                    'par30_kzt': a['par30_kzt'], 'par90_kzt': a['par90_kzt'],
                    'npl_kzt': a['npl_kzt'], 'provisions_kzt': a['provisions_kzt'],
                    'share_of_portfolio': div(a['portfolio_kzt'], pf),
                    'par30_share': div(a['par30_kzt'], a['portfolio_kzt']),
                    'par90_share': div(a['par90_kzt'], a['portfolio_kzt']),
                    'npl_share': div(a['npl_kzt'], a['portfolio_kzt']),
                    'prev_report_date': None, 'portfolio_chg_kzt': None,
                    'par30_chg_pp': None, 'par90_chg_pp': None, 'npl_chg_pp': None,
                }
                p = last_seen.get((dim, value))
                if p:
                    row.update({
                        'prev_report_date': p['report_date'],
                        'portfolio_chg_kzt': row['portfolio_kzt'] - p['portfolio_kzt'],
                        'par30_chg_pp': (row['par30_share'] - p['par30_share']) * HUNDRED,
                        'par90_chg_pp': (row['par90_share'] - p['par90_share']) * HUNDRED,
                        'npl_chg_pp': (row['npl_share'] - p['npl_share']) * HUNDRED,
                    })
                dim_rows.append(row)
                dim_index[(d, dim, value)] = row
        for row in dim_rows:
            if row['report_date'] == d:
                last_seen[(row['dimension'], row['dimension_value'])] = row

    # 4) v_top_groups
    top_rows, top10_par30 = [], {}
    for d in dates:
        port, pf, cum = port_of[d], M[d]['portfolio_kzt'], ZERO
        par30_in_top = ZERO
        for k, (gid, s) in enumerate(ranks[d][:10], start=1):
            g = port[port['group_id'] == gid]
            cum += s
            par30_amt = dsum(g['amount_kzt'][g['is_par30']])
            par30_in_top += par30_amt
            top_rows.append({
                'report_date': d, 'group_rank': k, 'group_id': gid, 'loan_count': len(g),
                'borrower_count': int(g['borrower_id'].nunique()), 'amount_kzt': s,
                'share_of_portfolio': div(s, pf), 'cumulative_share': div(cum, pf),
                'par30_amount_kzt': par30_amt,
                'npl_amount_kzt': dsum(g['amount_kzt'][g['is_npl']]),
                'max_days_past_due': int(g['days_past_due'].max()),
            })
        top10_par30[d] = div(par30_in_top, M[d]['top10_groups_kzt'])

    # 5–6) мост и миграция — по каждой паре соседних дат
    bridge_rows, migration_rows, pair_sets = [], [], {}
    for curr in dates[1:]:
        prev = prev_of[curr]
        P, C = by_date[prev], by_date[curr]
        both = [l for l in P if l in C and P[l]['in_portfolio'] and C[l]['in_portfolio']]
        start, end = M[prev]['portfolio_kzt'], M[curr]['portfolio_kzt']
        steps = [
            (2, 'repayment', 'Погашения основного долга',
             dsum((C[l]['principal_outstanding'] - P[l]['principal_outstanding']) * C[l]['fx_rate_kzt']
                  for l in both)),
            (3, 'fx', 'Переоценка USD по курсу',
             dsum(P[l]['principal_outstanding'] * (C[l]['fx_rate_kzt'] - P[l]['fx_rate_kzt'])
                  for l in both)),
            (4, 'written_off', 'Списаны за месяц',
             ZERO - dsum(P[l]['amount_kzt'] for l in P
                         if P[l]['in_portfolio'] and l in C and C[l]['is_written_off'])),
            (5, 'returned', 'Вернулись из списанных',
             dsum(C[l]['amount_kzt'] for l in C
                  if l in P and P[l]['is_written_off'] and C[l]['in_portfolio'])),
            (6, 'new', 'Новые кредиты',
             dsum(C[l]['amount_kzt'] for l in C if l not in P and C[l]['in_portfolio'])),
            (7, 'left', 'Выбыли из выгрузки',
             ZERO - dsum(P[l]['amount_kzt'] for l in P if P[l]['in_portfolio'] and l not in C)),
        ]
        base = {'prev_report_date': prev, 'report_date': curr}
        bridge_rows.append(dict(base, step_order=1, step_code='start', step_label='Портфель на начало',
                                step_kind='total', amount_kzt=start, bar_start_kzt=ZERO,
                                bar_end_kzt=start))
        running = start
        for order, code, label, delta in steps:
            bridge_rows.append(dict(base, step_order=order, step_code=code, step_label=label,
                                    step_kind='delta', amount_kzt=delta, bar_start_kzt=running,
                                    bar_end_kzt=running + delta))
            running += delta
        bridge_rows.append(dict(base, step_order=8, step_code='end', step_label='Портфель на конец',
                                step_kind='total', amount_kzt=end, bar_start_kzt=ZERO, bar_end_kzt=end))
        if running != end:   # мост обязан сходиться точно
            problems.append(f'мост {prev}→{curr} не сходится: {running} против {end}')

        cells = {}
        for l in sorted(set(P) | set(C)):
            fs, ts = state_of(P.get(l)), state_of(C.get(l))
            cell = cells.setdefault((fs, ts), [0, ZERO, ZERO])
            cell[0] += 1
            cell[1] += P[l]['amount_kzt'] if l in P else ZERO
            cell[2] += C[l]['amount_kzt'] if l in C else ZERO
        for (fs, ts), (n, fa, ta) in cells.items():
            migration_rows.append(dict(base, from_state=fs, from_order=STATE_ORDER[fs], to_state=ts,
                                       to_order=STATE_ORDER[ts], loan_count=n,
                                       from_amount_kzt=fa, to_amount_kzt=ta))

        pair_sets[curr] = {
            'cure': [l for l in P if l in C and state_of(P[l]) == S_90 and state_of(C[l]) == S_OK],
            'reversal': [l for l in P if l in C and P[l]['is_written_off'] and not C[l]['is_written_off']],
            'new_par30': [l for l in P if l in C and P[l]['in_portfolio'] and C[l]['in_portfolio']
                          and P[l]['days_past_due'] <= 30 and C[l]['days_past_due'] > 30],
            'jump_days': (date.fromisoformat(curr) - date.fromisoformat(prev)).days,
        }

    # 7) v_data_quality
    dq_rows = []
    for d in dates:
        recs = list(by_date[d].values())
        port_recs = [r for r in recs if r['in_portfolio']]
        wo_recs = [r for r in recs if r['is_written_off']]
        matured = [r for r in port_recs if r['is_past_maturity'] and r['days_past_due'] == 0]
        checks = {
            'duplicate_rows': (sum(r['source_rows'] - 1 for r in recs),
                               dsum((r['source_rows'] - 1) * r['amount_kzt'] for r in recs)),
            'conflicting_versions': (conflicts.get(d, 0), None),
            'missing_fx': (sum(r['fx_rate_kzt'] is None for r in recs), None),
            'non_positive_principal': (sum(r['principal_outstanding'] <= 0 for r in recs), None),
            'written_off': (len(wo_recs), dsum(r['amount_kzt'] for r in wo_recs)),
            'write_off_reversal': (None, None),
            'cure_from_90plus': (None, None),
            'past_maturity_zero_dpd': (len(matured), dsum(r['amount_kzt'] for r in matured)),
            'dpd_jump': (None, None),
            'restructured_written_off': (sum(r['is_restructured'] for r in wo_recs), None),
        }
        if d in pair_sets:
            ps, P, C = pair_sets[d], by_date[prev_of[d]], by_date[d]
            checks['write_off_reversal'] = (len(ps['reversal']),
                                            dsum(C[l]['amount_kzt'] for l in ps['reversal']))
            checks['cure_from_90plus'] = (len(ps['cure']), dsum(C[l]['amount_kzt'] for l in ps['cure']))
            checks['dpd_jump'] = (sum(C[l]['days_past_due'] - P[l]['days_past_due'] > ps['jump_days']
                                      for l in P if l in C), None)
        for code, (n, amount) in checks.items():
            dq_rows.append({'report_date': d, 'check_code': code, 'row_count': n, 'amount_kzt': amount})

    # 8) v_committee_facts — последняя пара срезов
    facts = []
    if len(dates) >= 2:
        facts = committee_facts(dates[-2], dates[-1], by_date, M, ranks, dim_index,
                                pair_sets[dates[-1]], top10_par30)

    expected = {
        'v_risk_metrics.json': risk_metrics,
        'v_risk_metrics_long.json': long_rows,
        'v_risk_by_dimension.json': dim_rows,
        'v_top_groups.json': top_rows,
        'v_portfolio_bridge.json': bridge_rows,
        'v_dpd_migration.json': migration_rows,
        'v_data_quality.json': dq_rows,
        'v_committee_facts.json': facts,
        'v_loans.json': loans,
    }

    # Внутренняя согласованность своего расчёта (не сверка с SQL)
    for d in dates:
        for dim in DIMENSIONS:
            s = dsum(r['portfolio_kzt'] for r in dim_rows if r['report_date'] == d and r['dimension'] == dim)
            if s != M[d]['portfolio_kzt']:
                problems.append(f'сумма по {dim} на {d} не равна портфелю')
    for curr in dates[1:]:
        n = sum(r['loan_count'] for r in migration_rows if r['report_date'] == curr)
        if n != len(set(by_date[prev_of[curr]]) | set(by_date[curr])):
            problems.append(f'миграция {curr}: число кредитов не равно объединению срезов')
    return expected, dates, M


def committee_facts(prev, curr, by_date, M, ranks, dim_index, ps, top10_par30):
    P, C = by_date[prev], by_date[curr]
    mp, mc = M[prev], M[curr]
    pf_c = mc['portfolio_kzt']
    rows = []

    def fact(order, code, value, display):
        rows.append({'fact_code': code, 'prev_report_date': prev, 'report_date': curr,
                     'fact_order': order, 'conclusion': order // 100, 'value': value,
                     'display': display})

    def opt(fn, v):
        return fn(v) if v is not None else None

    # 1xx — NPL, выздоровевшие и переходы
    cure = ps['cure']
    cure_curr = dsum(C[l]['amount_kzt'] for l in cure)
    fact(101, 'npl_prev', mp['npl_share'], fmt_pct(mp['npl_share'], 2))
    fact(102, 'npl_curr', mc['npl_share'], fmt_pct(mc['npl_share'], 2))
    v = (mc['npl_share'] - mp['npl_share']) * HUNDRED
    fact(103, 'npl_chg_pp', v, fmt_pp(v))
    v = mc['provisions_kzt'] - mp['provisions_kzt']
    fact(104, 'provisions_chg_kzt', v, fmt_bn_signed(v))
    fact(105, 'cure_n', len(cure), fmt_num(len(cure), 0))
    v = dsum(P[l]['amount_kzt'] for l in cure)
    fact(106, 'cure_prev_kzt', v, fmt_bn(v))
    v = div(mc['npl_kzt'] + cure_curr, pf_c)
    fact(109, 'npl_if_not_cured', v, fmt_pct(v, 2))
    v = cure_curr * Decimal('0.49')
    fact(110, 'provisions_if_not_cured', v, fmt_bn_signed(v))
    for order, code, frm, to in ((111, 'to_31_90', S_1_30, S_31_90), (113, 'to_90', S_31_90, S_90)):
        ids = [l for l in P if l in C and state_of(P[l]) == frm and state_of(C[l]) == to]
        fact(order, f'{code}_n', len(ids), fmt_num(len(ids), 0))
        v = dsum(C[l]['amount_kzt'] for l in ids)
        fact(order + 1, f'{code}_kzt', v, fmt_bn(v))

    # 2xx — крупнейший новый PAR30 и его группа
    new = sorted(ps['new_par30'], key=lambda l: (-C[l]['amount_kzt'], l))
    if new:
        loan = C[new[0]]
        gid, amt = loan['group_id'], loan['amount_kzt']
        rank, gsum = next((i, s) for i, (g, s) in enumerate(ranks[curr], start=1) if g == gid)
        fact(201, 'new_par30_group', None, gid)
        fact(202, 'new_par30_group_rank', rank, fmt_num(rank, 0))
        fact(203, 'new_par30_group_kzt', gsum, fmt_bn(gsum))
        v = div(gsum, pf_c)
        fact(204, 'new_par30_group_share', v, fmt_pct(v, 1))
        fact(205, 'new_par30_loan', None, loan['loan_id'])
        fact(206, 'new_par30_loan_kzt', amt, fmt_bn(amt))
        fact(207, 'new_par30_loan_dpd', loan['days_past_due'], fmt_num(loan['days_past_due'], 0))
        fact(208, 'new_par30_sector', None, loan['sector'])
        for order, code, d in ((209, 'sector_par30_prev', prev), (210, 'sector_par30_curr', curr)):
            row = dim_index.get((d, 'sector', loan['sector']))
            v = row['par30_share'] if row else None
            fact(order, code, v, opt(lambda x: fmt_pct(x, 1), v))
        v = div(amt, pf_c) * HUNDRED
        fact(211, 'roll_npl_pp', v, fmt_signed(v, 1) + ' п.п.')
        v = amt * Decimal('0.40')
        fact(212, 'roll_provisions_kzt', v, fmt_bn_signed(v))
    v = top10_par30[prev]
    fact(213, 'top10_par30_prev', v, fmt_pct(v, 1))
    v = top10_par30[curr]
    fact(214, 'top10_par30_curr', v, fmt_pct(v, 1))
    fact(215, 'par30_prev', mp['par30_share'], fmt_pct(mp['par30_share'], 1))
    fact(216, 'par30_curr', mc['par30_share'], fmt_pct(mc['par30_share'], 1))
    # 217: PAR30 отрасли, если бы этот кредит остался в 0–30 дней (знаменатель тот же)
    if new:
        row = dim_index.get((curr, 'sector', loan['sector']))
        v = div(row['par30_kzt'] - amt, row['portfolio_kzt']) if row else None
        fact(217, 'sector_par30_without_loan', v, opt(lambda x: fmt_pct(x, 1), v))

    # 3xx — реструктуризированные и просроченные по сроку
    restr = [r for r in C.values() if r['in_portfolio'] and r['is_restructured']]
    restr_kzt = dsum(r['amount_kzt'] for r in restr)
    restr_prov = dsum(r['provision_kzt'] for r in restr)
    fact(301, 'restr_n', len(restr), fmt_num(len(restr), 0))
    fact(302, 'restr_kzt', restr_kzt, fmt_bn(restr_kzt))
    v = div(restr_kzt, pf_c)
    fact(303, 'restr_share', v, fmt_pct(v, 1))
    v = max((r['days_past_due'] for r in restr), default=None)
    fact(304, 'restr_max_dpd', v, opt(lambda x: fmt_num(x, 0), v))
    v = div(restr_kzt, mc['npl_kzt'])
    fact(305, 'restr_share_of_npl', v, fmt_pct(v, 0))
    fact(306, 'restr_provisions_kzt', restr_prov, fmt_bn(restr_prov))
    v = div(restr_prov, mc['provisions_kzt'])
    fact(307, 'restr_share_of_prov', v, fmt_pct(v, 0))
    matured = [r for r in C.values()
               if r['in_portfolio'] and r['is_past_maturity'] and r['days_past_due'] == 0]
    mat_kzt = dsum(r['amount_kzt'] for r in matured)
    fact(308, 'matured_n', len(matured), fmt_num(len(matured), 0))
    fact(309, 'matured_kzt', mat_kzt, fmt_bn(mat_kzt))
    v = div(mat_kzt, pf_c)
    fact(310, 'matured_share', v, fmt_pct(v, 1))
    mat_nr = [r for r in matured if not r['is_restructured']]
    mat_nr_kzt = dsum(r['amount_kzt'] for r in mat_nr)
    fact(311, 'matured_not_restr_n', len(mat_nr), fmt_num(len(mat_nr), 0))
    fact(312, 'matured_not_restr_kzt', mat_nr_kzt, fmt_bn(mat_nr_kzt))
    v = div(mat_nr_kzt, pf_c)
    fact(313, 'matured_not_restr_share', v, fmt_pct(v, 1))

    # 4xx — качество данных: дубли прошлого среза и возвраты из списанных
    dup_recs = [r for r in P.values() if r['in_portfolio']]
    dup_n = sum(r['source_rows'] - 1 for r in dup_recs)
    dup_kzt = dsum((r['source_rows'] - 1) * r['amount_kzt'] for r in dup_recs)
    fact(401, 'dup_rows', dup_n, fmt_num(dup_n, 0))
    fact(402, 'dup_kzt', dup_kzt, fmt_bn(dup_kzt))
    v = div(dup_kzt, mp['portfolio_kzt'])
    fact(403, 'dup_share', v, fmt_pct(v, 1))
    rev = ps['reversal']
    rev_kzt = dsum(C[l]['amount_kzt'] for l in rev)
    rev_npl = [l for l in rev if state_of(C[l]) == S_90]
    rev_npl_kzt = dsum(C[l]['amount_kzt'] for l in rev_npl)
    fact(404, 'reversal_n', len(rev), fmt_num(len(rev), 0))
    fact(405, 'reversal_kzt', rev_kzt, fmt_bn(rev_kzt))
    fact(406, 'reversal_npl_n', len(rev_npl), fmt_num(len(rev_npl), 0))
    fact(407, 'reversal_npl_kzt', rev_npl_kzt, fmt_bn(rev_npl_kzt))
    pf_irr = pf_c - rev_kzt
    npl_irr = div(mc['npl_kzt'] - rev_npl_kzt, pf_irr)
    # 408: на сколько NPL выше из-за возвратов — разница долей, а не доля их суммы в портфеле
    v = (mc['npl_share'] - npl_irr) * HUNDRED
    fact(408, 'reversal_npl_pp', v, fmt_num(v, 2) + ' п.п.')
    fact(409, 'portfolio_if_irreversible', pf_irr, fmt_bn(pf_irr))
    fact(410, 'npl_if_irreversible', npl_irr, fmt_pct(npl_irr, 2))
    rev_zero = [l for l in rev if state_of(C[l]) == S_OK]
    rev_zero_kzt = dsum(C[l]['amount_kzt'] for l in rev_zero)
    fact(411, 'reversal_zero_n', len(rev_zero), fmt_num(len(rev_zero), 0))
    fact(412, 'reversal_zero_kzt', rev_zero_kzt, fmt_bn(rev_zero_kzt))
    return rows


# ---------- сравнение ----------

def field_kind(fname, field, row):
    if fname == 'v_risk_metrics_long.json' and field in ('value', 'prev_value', 'change_abs'):
        return 'share' if row.get('unit') == 'share' else 'exact'
    if fname == 'v_committee_facts.json' and field == 'value':
        return FACT_KIND.get(row.get('fact_code'), 'exact')
    if field.endswith('_pp'):
        return 'pp'
    if field.endswith('_share') or field.endswith('_rel') or field == 'share_of_portfolio':
        return 'share'
    return 'exact'


def same(sql, py, kind):
    if sql is None or py is None:
        return sql is None and py is None
    if isinstance(sql, bool) or isinstance(py, bool):      # bool — подкласс int, ловим до чисел
        return type(sql) is bool and type(py) is bool and sql == py
    if isinstance(sql, str) or isinstance(py, str):
        return type(sql) is str and type(py) is str and sql == py
    if isinstance(sql, list) or isinstance(py, list):
        return (isinstance(sql, list) and isinstance(py, list) and len(sql) == len(py)
                and all(same(a, b, 'exact') for a, b in zip(sql, py)))
    if not isinstance(sql, (int, Decimal)) or not isinstance(py, (int, Decimal)):
        return False
    diff = Decimal(sql) - Decimal(py)
    tol = TOL[kind]
    return diff == 0 if tol is None else abs(diff) <= tol


def compare_file(fname, sql_rows, py_rows):
    """Сверка одной выгрузки. Возвращает (число сверенных значений, список расхождений)."""
    keys = KEYS[fname]
    mismatches, compared = [], 0
    sql_by_key = {}
    for r in sql_rows:
        k = tuple(r.get(f) for f in keys)
        if k in sql_by_key:
            mismatches.append((k, '<строка>', 'ключ повторяется', '—'))
        sql_by_key[k] = r
    py_by_key = {tuple(r[f] for f in keys): r for r in py_rows}
    for k, py in py_by_key.items():
        sql = sql_by_key.get(k)
        if sql is None:
            mismatches.append((k, '<строка>', 'нет строки', 'есть'))
            continue
        for field, pv in py.items():
            if field in keys:
                continue
            compared += 1
            if field not in sql:
                mismatches.append((k, field, '<нет поля>', pv))
            elif not same(sql[field], pv, field_kind(fname, field, py)):
                mismatches.append((k, field, sql[field], pv))
    for k in sql_by_key:
        if k not in py_by_key:
            mismatches.append((k, '<строка>', 'лишняя строка', 'нет'))
    return compared, mismatches


def sql_only_fields(fname, sql_rows, py_rows):
    """Поля выгрузки SQL, которых нет в своём расчёте: они не сверяются, и это надо видеть."""
    sql_fields = {f for r in sql_rows for f in r}
    py_fields = {f for r in py_rows for f in r}
    return sorted(sql_fields - py_fields)


def show(v):
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, str):
        return repr(v)
    return str(v)


def load_json(path):
    """Читает выгрузку без потери точности. Возвращает (строки, ошибка)."""
    if not path.exists():
        return None, f'файл не найден: {path}'
    text = path.read_text(encoding='utf-8')
    if not text.strip():
        return None, f'файл пустой: {path}'
    rows = json.loads(text, parse_float=Decimal, parse_int=int)
    if not isinstance(rows, list):
        return None, f'ожидался массив объектов: {path}'
    if not rows:
        return None, f'в файле нет строк: {path}'
    return rows, None


def load_actual(args):
    actual, errors = {}, {}
    for fname in KEYS:
        path = args.loans_file if fname == 'v_loans.json' else args.exports_dir / fname
        rows, err = load_json(path)
        if err:
            errors[fname] = err
        else:
            actual[fname] = rows
    return actual, errors


# ---------- самопроверка сравнения ----------

def self_test(expected, actual, errors):
    print('Самопроверка сравнения')
    failed = 0

    def report(name, ok):
        nonlocal failed
        failed += not ok
        print(f'  [{"ок" if ok else "ОШИБКА"}] {name}')

    # Контроль: значение против самого себя обязано совпадать (и эталон, и выгрузка)
    for fname, rows in expected.items():
        n, mm = compare_file(fname, copy.deepcopy(rows), rows)
        report(f'{fname}: расчёт против своей копии — {n} значений, расхождений {len(mm)}',
               n > 0 and not mm)
    for fname, rows in actual.items():
        n, mm = compare_file(fname, copy.deepcopy(rows), rows)
        report(f'{fname}: выгрузка против своей копии — {n} значений, расхождений {len(mm)}',
               n > 0 and not mm)

    # Форматтер: в данных нет ни одной «половинки», поэтому правило округления проверяем прямо
    for got, want in ((fmt_num(Decimal('498153228694.573'), 2), '498 153 228 694,57'),
                      (fmt_num(Decimal('0.125'), 2), '0,13'),
                      (fmt_num(Decimal('-0.125'), 2), f'{MINUS}0,13'),
                      (fmt_num(Decimal('-0.004'), 2), '0,00'),
                      (fmt_signed(Decimal('0.004'), 2), '0,00'),
                      (fmt_signed(Decimal('2.5'), 0), '+3'),
                      (fmt_num(Decimal('999.95'), 1), '1 000,0'),
                      (fmt_num(100, 0), '100'),
                      (fmt_bn_signed(Decimal('-5341017657.92094')), f'{MINUS}5,3 млрд {TENGE}'),
                      (fmt_pp(Decimal('-1.8372661727903659')), f'{MINUS}1,84 п.п.'),
                      (fmt_pct_signed(Decimal('0.0005'), 1), '+0,1%')):
        report(f'форматтер: {got!r} = {want!r}', got == want)

    # Допуски на эталоне (базовая разница ровно 0): в допуске — не ловится, за ним — ловится
    rm = 'v_risk_metrics.json'
    for field, delta, must_catch in (('par30_share', Decimal('1e-16'), False),
                                     ('par30_share', Decimal('1e-14'), True),
                                     ('par30_chg_pp', Decimal('1e-14'), False),
                                     ('par30_chg_pp', Decimal('1e-12'), True)):
        rows = copy.deepcopy(expected[rm])
        row = next(r for r in rows if r[field] is not None)
        row[field] += delta
        _, mm = compare_file(rm, rows, expected[rm])
        caught = any(m[1] == field for m in mm)
        report(f'допуск: {field} + {delta} {"ловится" if must_catch else "в допуске"}',
               caught == must_catch)

    # Порчи реальной выгрузки: каждая обязана дать новое расхождение в своём месте
    def first(rows, pred):
        return next((i for i, r in enumerate(rows) if pred(r)), None)

    def bump(field, delta):
        def apply(rows):
            i = first(rows, lambda r: isinstance(r.get(field), (int, Decimal))
                      and not isinstance(r.get(field), bool))
            rows[i][field] = rows[i][field] + delta
            return i, field
        return apply

    def relabel(rows):
        i = first(rows, lambda r: isinstance(r.get('change_display'), str) and MINUS in r['change_display'])
        rows[i]['change_display'] = rows[i]['change_display'].replace(MINUS, '-')   # дефис вместо минуса
        return i, 'change_display'

    def flip(rows):
        rows[0]['is_npl'] = not rows[0]['is_npl']
        return 0, 'is_npl'

    def null_to_zero(rows):
        i = first(rows, lambda r: r.get('portfolio_chg_kzt') is None)
        rows[i]['portfolio_chg_kzt'] = 0
        return i, 'portfolio_chg_kzt'

    def extra_row(rows):
        extra = copy.deepcopy(rows[-1])
        extra['group_rank'] = 11
        rows.append(extra)
        return len(rows) - 1, '<строка>'

    def drop_row(rows):
        drop_row.lost = rows.pop(0)    # ключ пропавшей строки берём из неё самой
        return None, '<строка>'

    corruptions = [
        ('сумма +0.01', 'v_risk_metrics.json', bump('portfolio_kzt', Decimal('0.01'))),
        ('сумма +0.01 (кредит)', 'v_loans.json', bump('amount_kzt', Decimal('0.01'))),
        ('количество +1', 'v_top_groups.json', bump('loan_count', 1)),
        ('доля +1e-9', 'v_risk_metrics.json', bump('par30_share', Decimal('1e-9'))),
        ('п.п. +1e-9', 'v_risk_by_dimension.json', bump('npl_chg_pp', Decimal('1e-9'))),
        ('подпись: дефис вместо минуса', 'v_risk_metrics_long.json', relabel),
        ('флаг is_npl перевёрнут', 'v_loans.json', flip),
        ('null заменён на 0', 'v_risk_metrics.json', null_to_zero),
        ('лишняя строка', 'v_top_groups.json', extra_row),
        ('пропавшая строка', 'v_dpd_migration.json', drop_row),
    ]
    for name, fname, apply in corruptions:
        if fname not in actual:
            report(f'{name} ({fname}): не проверено — {errors.get(fname)}', False)
            continue
        _, base = compare_file(fname, actual[fname], expected[fname])
        base_ids = {(m[0], m[1]) for m in base}
        rows = copy.deepcopy(actual[fname])
        i, field = apply(rows)
        src = drop_row.lost if apply is drop_row else rows[i]
        key = tuple(src.get(f) for f in KEYS[fname])
        _, mm = compare_file(fname, rows, expected[fname])
        new_ids = {(m[0], m[1]) for m in mm} - base_ids
        report(f'{name} ({fname}, {key}, {field}): {"поймана" if (key, field) in new_ids else "НЕ поймана"}',
               (key, field) in new_ids)
    print(f'Итог самопроверки: {"все проверки пройдены" if not failed else f"не пройдено {failed}"}')
    return 1 if failed else 0


# ---------- запуск ----------

def main():
    ap = argparse.ArgumentParser(description='Независимый пересчёт витрин из сырых CSV и сверка с SQL')
    ap.add_argument('--exports-dir', type=Path, default=ROOT / 'dashboard' / 'data')
    ap.add_argument('--loans-file', type=Path, default=ROOT / '.tmp' / 'export' / 'v_loans.json')
    ap.add_argument('--self-test', action='store_true',
                    help='проверить, что сравнение ловит порчу каждого вида')
    args = ap.parse_args()

    problems = []
    expected, dates, M = build_expected(problems)
    actual, errors = load_actual(args)

    if args.self_test:
        return self_test(expected, actual, errors)

    print(f'Срезы: {", ".join(dates)}')
    print('Свой расчёт (Python):')
    for d in dates:
        m = M[d]
        print(f'  {d}: портфель {m["portfolio_kzt"]} ₸, PAR30 {m["par30_share"]:.6f}, '
              f'PAR90 {m["par90_share"]:.6f}, NPL {m["npl_share"]:.6f}, '
              f'провизии {m["provisions_kzt"]} ₸, топ-10 {m["top10_share"]:.6f}')
    for p in problems:
        print(f'ОШИБКА ДАННЫХ ИЛИ РАСЧЁТА: {p}')

    total, total_mm = 0, 0
    for fname in KEYS:
        if fname in errors:
            loud = '!!! ' if fname == 'v_loans.json' else ''
            print(f'{loud}{fname}: {errors[fname]} — сверка невозможна, это расхождение')
            total_mm += 1
            continue
        n, mm = compare_file(fname, actual[fname], expected[fname])
        total += n
        total_mm += len(mm)
        print(f'{fname}: строк SQL {len(actual[fname])}, Python {len(expected[fname])}; '
              f'сверено значений {n}, расхождений {len(mm)}')
        skipped = sql_only_fields(fname, actual[fname], expected[fname])
        if skipped:
            print(f'  не сверяются (подписи и служебные поля, в спецификации их нет): {", ".join(skipped)}')
        for key, field, sql, py in mm[:200]:
            print(f'  {fname} | {key} | {field} | SQL {show(sql)} | Python {show(py)}')
        if len(mm) > 200:
            print(f'  … и ещё {len(mm) - 200}')

    unknown = sorted(p.name for p in args.exports_dir.glob('*.json') if p.name not in KEYS)
    if unknown:
        print(f'Не сверяются (нет в спецификации): {", ".join(unknown)}')
    total_mm += len(problems)
    if 'v_loans.json' in errors:
        print(f'!!! ВНИМАНИЕ: v_loans.json НЕ СВЕРЕН ({errors["v_loans.json"]})', file=sys.stderr)
    print(f'Итог: сверено {total} значений, расхождений {total_mm}')
    return 1 if total_mm else 0


if __name__ == '__main__':
    sys.exit(main())
