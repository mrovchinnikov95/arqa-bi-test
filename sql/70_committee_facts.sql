-- Факты для выводов риск-комитету и раздела о качестве данных в README.
-- Каждое число в выводах берётся отсюда (колонка display), а checks/verify_independent.py
-- пересчитывает его заново из CSV и сверяет с README. Факты считаются для последней пары срезов.

CREATE OR REPLACE VIEW reporting.v_committee_facts AS
WITH d AS (
    SELECT prev_report_date AS prev_date, report_date AS curr_date
    FROM reporting.v_snapshot_pairs
    ORDER BY report_date DESC
    LIMIT 1
),
mc AS (SELECT m.* FROM reporting.v_risk_metrics m JOIN d ON m.report_date = d.curr_date),
mp AS (SELECT m.* FROM reporting.v_risk_metrics m JOIN d ON m.report_date = d.prev_date),
lp AS (SELECT l.* FROM reporting.v_loan_pairs l JOIN d ON l.report_date = d.curr_date),
pc AS (SELECT p.* FROM reporting.v_portfolio p JOIN d ON p.report_date = d.curr_date),

-- Вывод 1. «Излечения» из 90+ и что было бы без них.
-- Сценарные ставки берутся из reporting.provision_rate(): «если бы кредит был в 90+» = ставка для 91 дня.
cure AS (
    SELECT
        count(*)                AS n,
        sum(prev_amount_kzt)    AS prev_kzt,
        sum(curr_amount_kzt)    AS curr_kzt,
        sum(curr_amount_kzt * (reporting.provision_rate(91, false)
                               - reporting.provision_rate(curr_days_past_due, false))) AS extra_provisions_kzt
    FROM lp WHERE is_cure_from_90plus
),
mig AS (
    SELECT
        sum(loan_count)    FILTER (WHERE from_state = 'Просрочка 1–30'  AND to_state = 'Просрочка 31–90')    AS to_31_90_n,
        sum(to_amount_kzt) FILTER (WHERE from_state = 'Просрочка 1–30'  AND to_state = 'Просрочка 31–90')    AS to_31_90_kzt,
        sum(loan_count)    FILTER (WHERE from_state = 'Просрочка 31–90' AND to_state = 'NPL: просрочка 90+') AS to_90_n,
        sum(to_amount_kzt) FILTER (WHERE from_state = 'Просрочка 31–90' AND to_state = 'NPL: просрочка 90+') AS to_90_kzt
    FROM reporting.v_dpd_migration m JOIN d ON m.report_date = d.curr_date
),

-- Вывод 2. Самый крупный кредит, впервые ушедший в PAR30, и его группа.
new_par30 AS (
    SELECT lp.loan_id, lp.group_id, lp.sector, lp.curr_days_past_due, lp.curr_amount_kzt,
           lp.curr_amount_kzt * (reporting.provision_rate(91, false)
                                 - reporting.provision_rate(lp.curr_days_past_due, false)) AS roll_extra_provisions_kzt
    FROM lp
    WHERE is_new_par30
    ORDER BY lp.curr_amount_kzt DESC, lp.loan_id
    LIMIT 1
),
-- Место группы считается среди всех групп (не только топ-10); агрегат всегда даёт одну строку.
grp AS (
    SELECT max(group_rank) AS group_rank, max(amount_kzt) AS amount_kzt, max(share_of_portfolio) AS share_of_portfolio
    FROM (
        SELECT group_id,
               row_number() OVER (ORDER BY sum(amount_kzt) DESC, group_id) AS group_rank,
               sum(amount_kzt)                                     AS amount_kzt,
               sum(amount_kzt) / sum(sum(amount_kzt)) OVER ()      AS share_of_portfolio
        FROM pc GROUP BY group_id
    ) g
    WHERE g.group_id = (SELECT group_id FROM new_par30)
),
sector AS (
    SELECT
        max(par30_share) FILTER (WHERE r.report_date = d.prev_date) AS prev_par30,
        max(par30_share) FILTER (WHERE r.report_date = d.curr_date) AS curr_par30,
        max(par30_kzt)     FILTER (WHERE r.report_date = d.curr_date) AS curr_par30_kzt,
        max(portfolio_kzt) FILTER (WHERE r.report_date = d.curr_date) AS curr_portfolio_kzt
    FROM reporting.v_risk_by_dimension r CROSS JOIN d
    WHERE r.dimension = 'sector' AND r.dimension_value = (SELECT sector FROM new_par30)
),
top10 AS (
    SELECT
        sum(par30_amount_kzt) FILTER (WHERE t.report_date = d.prev_date)
          / sum(amount_kzt)   FILTER (WHERE t.report_date = d.prev_date) AS prev_par30,
        sum(par30_amount_kzt) FILTER (WHERE t.report_date = d.curr_date)
          / sum(amount_kzt)   FILTER (WHERE t.report_date = d.curr_date) AS curr_par30
    FROM reporting.v_top_groups t CROSS JOIN d
),

-- Вывод 3. Реструктуризация и кредиты с истёкшим сроком без просрочки.
restr AS (
    SELECT count(*) AS n, sum(amount_kzt) AS kzt, sum(provision_kzt) AS provisions_kzt,
           max(days_past_due) AS max_dpd
    FROM pc WHERE is_restructured
),
matured AS (
    SELECT count(*) AS n, sum(amount_kzt) AS kzt,
           count(*) FILTER (WHERE NOT is_restructured)                       AS not_restr_n,
           coalesce(sum(amount_kzt) FILTER (WHERE NOT is_restructured), 0)    AS not_restr_kzt
    FROM pc WHERE is_past_maturity AND days_past_due = 0
),

-- Качество данных: дубли, возвраты из списанных, чувствительность к правилу списания.
dup AS (
    SELECT sum((v.source_rows - 1) * v.amount_kzt) AS kzt, sum(v.source_rows - 1) AS n
    FROM reporting.v_loans v JOIN d ON v.report_date = d.prev_date
    WHERE v.in_portfolio
),
rev AS (
    SELECT
        count(*)                                                         AS n,
        sum(curr_amount_kzt)                                             AS kzt,
        count(*)             FILTER (WHERE curr_state = 'NPL: просрочка 90+') AS npl_n,
        coalesce(sum(curr_amount_kzt) FILTER (WHERE curr_state = 'NPL: просрочка 90+'), 0) AS npl_kzt,
        count(*)             FILTER (WHERE curr_state = 'Без просрочки')      AS zero_n,
        coalesce(sum(curr_amount_kzt) FILTER (WHERE curr_state = 'Без просрочки'), 0) AS zero_kzt
    FROM lp WHERE is_write_off_reversal
),
-- Источники ниже дают ровно одну строку: агрегаты без GROUP BY, а mc и mp — строки v_risk_metrics на две даты.
-- Если среза меньше двух, mc или mp пустые и фактов нет совсем — это ловит проверка 46 в sql/90_checks.sql.
f AS (
    SELECT v.*
    FROM mc, mp, cure, mig, grp, sector, top10, restr, matured, dup, rev,
    LATERAL (VALUES
        -- вывод 1
        (101, 1, 'npl_prev',             'NPL на прошлом срезе',                     mp.npl_share,      reporting.fmt_pct(mp.npl_share)),
        (102, 1, 'npl_curr',             'NPL на текущем срезе',                     mc.npl_share,      reporting.fmt_pct(mc.npl_share)),
        (103, 1, 'npl_chg_pp',           'Изменение NPL',                            mc.npl_chg_pp,     reporting.fmt_pp(mc.npl_chg_pp)),
        (104, 1, 'provisions_chg_kzt',   'Изменение провизий',                       mc.provisions_chg_kzt, reporting.fmt_bn_signed(mc.provisions_chg_kzt)),
        (105, 1, 'cure_n',               'Кредитов вышло из 90+ в «без просрочки»',  cure.n::numeric,   reporting.fmt_num(cure.n, 0)),
        (106, 1, 'cure_prev_kzt',        'Их остаток на прошлом срезе',              cure.prev_kzt,     reporting.fmt_bn(cure.prev_kzt)),
        (109, 1, 'npl_if_not_cured',     'NPL, если «излечения» не подтвердятся',    (mc.npl_kzt + cure.curr_kzt) / mc.portfolio_kzt,
                                                                                     reporting.fmt_pct((mc.npl_kzt + cure.curr_kzt) / mc.portfolio_kzt)),
        (110, 1, 'provisions_if_not_cured', 'Доначисление провизий в этом случае (ставка 90+ вместо текущей)', cure.extra_provisions_kzt,
                                                                                     reporting.fmt_bn_signed(cure.extra_provisions_kzt)),
        (111, 1, 'to_31_90_n',           'Перешли из 1–30 в 31–90',                  mig.to_31_90_n,    reporting.fmt_num(mig.to_31_90_n, 0)),
        (112, 1, 'to_31_90_kzt',         'Их остаток',                               mig.to_31_90_kzt,  reporting.fmt_bn(mig.to_31_90_kzt)),
        (113, 1, 'to_90_n',              'Перешли из 31–90 в 90+',                   mig.to_90_n,       reporting.fmt_num(mig.to_90_n, 0)),
        (114, 1, 'to_90_kzt',            'Их остаток',                               mig.to_90_kzt,     reporting.fmt_bn(mig.to_90_kzt)),
        -- вывод 2
        (201, 2, 'new_par30_group',      'Группа крупнейшего кредита, ушедшего в PAR30', NULL::numeric, (SELECT group_id FROM new_par30)),
        (202, 2, 'new_par30_group_rank', 'Место группы по портфелю',                 grp.group_rank::numeric, reporting.fmt_num(grp.group_rank, 0)),
        (203, 2, 'new_par30_group_kzt',  'Портфель группы',                          grp.amount_kzt,    reporting.fmt_bn(grp.amount_kzt)),
        (204, 2, 'new_par30_group_share','Доля группы в портфеле',                   grp.share_of_portfolio, reporting.fmt_pct(grp.share_of_portfolio, 1)),
        (205, 2, 'new_par30_loan',       'Кредит',                                   NULL, (SELECT loan_id FROM new_par30)),
        (206, 2, 'new_par30_loan_kzt',   'Остаток кредита',                          (SELECT curr_amount_kzt FROM new_par30), reporting.fmt_bn((SELECT curr_amount_kzt FROM new_par30))),
        (207, 2, 'new_par30_loan_dpd',   'Просрочка кредита, дней',                  (SELECT curr_days_past_due FROM new_par30)::numeric, reporting.fmt_num((SELECT curr_days_past_due FROM new_par30), 0)),
        (208, 2, 'new_par30_sector',     'Отрасль кредита',                          NULL, (SELECT sector FROM new_par30)),
        (209, 2, 'sector_par30_prev',    'PAR30 отрасли на прошлом срезе',           sector.prev_par30, reporting.fmt_pct(sector.prev_par30, 1)),
        (210, 2, 'sector_par30_curr',    'PAR30 отрасли на текущем срезе',           sector.curr_par30, reporting.fmt_pct(sector.curr_par30, 1)),
        (211, 2, 'roll_npl_pp',          'Рост NPL, если кредит уйдёт в 90+',        (SELECT curr_amount_kzt FROM new_par30) / mc.portfolio_kzt * 100,
                                                                                     reporting.fmt_signed((SELECT curr_amount_kzt FROM new_par30) / mc.portfolio_kzt * 100, 1) || ' п.п.'),
        (212, 2, 'roll_provisions_kzt',  'Доначисление провизий в этом случае (ставка 90+ вместо текущей)', (SELECT roll_extra_provisions_kzt FROM new_par30),
                                                                                     reporting.fmt_bn_signed((SELECT roll_extra_provisions_kzt FROM new_par30))),
        (213, 2, 'top10_par30_prev',     'PAR30 топ-10 групп на прошлом срезе',      top10.prev_par30,  reporting.fmt_pct(top10.prev_par30, 1)),
        (214, 2, 'top10_par30_curr',     'PAR30 топ-10 групп на текущем срезе',      top10.curr_par30,  reporting.fmt_pct(top10.curr_par30, 1)),
        (215, 2, 'par30_prev',           'PAR30 портфеля на прошлом срезе',          mp.par30_share,    reporting.fmt_pct(mp.par30_share, 1)),
        (216, 2, 'par30_curr',           'PAR30 портфеля на текущем срезе',          mc.par30_share,    reporting.fmt_pct(mc.par30_share, 1)),
        (217, 2, 'sector_par30_without_loan', 'PAR30 отрасли, если бы этот кредит остался в 0–30 дней',
                                                                                     (sector.curr_par30_kzt - (SELECT curr_amount_kzt FROM new_par30)) / sector.curr_portfolio_kzt,
                                                                                     reporting.fmt_pct((sector.curr_par30_kzt - (SELECT curr_amount_kzt FROM new_par30)) / sector.curr_portfolio_kzt, 1)),
        -- вывод 3
        (301, 3, 'restr_n',              'Реструктуризированных кредитов',           restr.n::numeric,  reporting.fmt_num(restr.n, 0)),
        (302, 3, 'restr_kzt',            'Их остаток',                               restr.kzt,         reporting.fmt_bn(restr.kzt)),
        (303, 3, 'restr_share',          'Доля в портфеле',                          restr.kzt / mc.portfolio_kzt, reporting.fmt_pct(restr.kzt / mc.portfolio_kzt, 1)),
        (304, 3, 'restr_max_dpd',        'Максимальная просрочка среди них, дней',   restr.max_dpd::numeric, reporting.fmt_num(restr.max_dpd, 0)),
        (305, 3, 'restr_share_of_npl',   'Доля реструктуризации в NPL',              restr.kzt / mc.npl_kzt, reporting.fmt_pct(restr.kzt / mc.npl_kzt, 0)),
        (306, 3, 'restr_provisions_kzt', 'Провизии по ним',                          restr.provisions_kzt, reporting.fmt_bn(restr.provisions_kzt)),
        (307, 3, 'restr_share_of_prov',  'Доля в провизиях',                         restr.provisions_kzt / mc.provisions_kzt, reporting.fmt_pct(restr.provisions_kzt / mc.provisions_kzt, 0)),
        (308, 3, 'matured_n',            'Срок прошёл, остаток есть, просрочки нет: кредитов', matured.n::numeric, reporting.fmt_num(matured.n, 0)),
        (309, 3, 'matured_kzt',          'Их остаток',                               matured.kzt,       reporting.fmt_bn(matured.kzt)),
        (310, 3, 'matured_share',        'Доля в портфеле',                          matured.kzt / mc.portfolio_kzt, reporting.fmt_pct(matured.kzt / mc.portfolio_kzt, 1)),
        (311, 3, 'matured_not_restr_n',  'Из них без отметки о реструктуризации: кредитов', matured.not_restr_n::numeric, reporting.fmt_num(matured.not_restr_n, 0)),
        (312, 3, 'matured_not_restr_kzt', 'Их остаток',                              matured.not_restr_kzt, reporting.fmt_bn(matured.not_restr_kzt)),
        (313, 3, 'matured_not_restr_share', 'Доля в портфеле',                       matured.not_restr_kzt / mc.portfolio_kzt, reporting.fmt_pct(matured.not_restr_kzt / mc.portfolio_kzt, 1)),
        -- качество данных
        (401, 4, 'dup_rows',             'Лишних строк-дублей на прошлом срезе (в портфеле)', dup.n,  reporting.fmt_num(dup.n, 0)),
        (402, 4, 'dup_kzt',              'На сколько дубли завысили бы портфель',    dup.kzt,           reporting.fmt_bn(dup.kzt)),
        (403, 4, 'dup_share',            'То же в процентах портфеля',               dup.kzt / mp.portfolio_kzt, reporting.fmt_pct(dup.kzt / mp.portfolio_kzt, 1)),
        (404, 4, 'reversal_n',           'Вернулись из списанных',                   rev.n::numeric,    reporting.fmt_num(rev.n, 0)),
        (405, 4, 'reversal_kzt',         'Их остаток',                               rev.kzt,           reporting.fmt_bn(rev.kzt)),
        (406, 4, 'reversal_npl_n',       'Из них сейчас в 90+',                      rev.npl_n::numeric, reporting.fmt_num(rev.npl_n, 0)),
        (407, 4, 'reversal_npl_kzt',     'Их остаток',                               rev.npl_kzt,       reporting.fmt_bn(rev.npl_kzt)),
        -- На сколько NPL выше из-за возвратов: разница с NPL без них (меняются и числитель, и знаменатель).
        (408, 4, 'reversal_npl_pp',      'На сколько п.п. NPL выше из-за возвратов из списанных',
                                                                                     (mc.npl_share - (mc.npl_kzt - rev.npl_kzt) / (mc.portfolio_kzt - rev.kzt)) * 100,
                                                                                     reporting.fmt_num((mc.npl_share - (mc.npl_kzt - rev.npl_kzt) / (mc.portfolio_kzt - rev.kzt)) * 100, 2) || ' п.п.'),
        (409, 4, 'portfolio_if_irreversible', 'Портфель, если списание необратимо',  mc.portfolio_kzt - rev.kzt, reporting.fmt_bn(mc.portfolio_kzt - rev.kzt)),
        (410, 4, 'npl_if_irreversible',  'NPL, если списание необратимо',            (mc.npl_kzt - rev.npl_kzt) / (mc.portfolio_kzt - rev.kzt),
                                                                                     reporting.fmt_pct((mc.npl_kzt - rev.npl_kzt) / (mc.portfolio_kzt - rev.kzt))),
        (411, 4, 'reversal_zero_n',      'Из них вернулись без просрочки',           rev.zero_n::numeric, reporting.fmt_num(rev.zero_n, 0)),
        (412, 4, 'reversal_zero_kzt',    'Их остаток',                               rev.zero_kzt,      reporting.fmt_bn(rev.zero_kzt))
    ) AS v(fact_order, conclusion, fact_code, fact_label, value, display)
)
SELECT d.prev_date AS prev_report_date, d.curr_date AS report_date, f.*
FROM f CROSS JOIN d;

COMMENT ON VIEW reporting.v_committee_facts IS
    'Числа для выводов риск-комитету: значение и готовая подпись. README берёт числа только отсюда и из v_risk_metrics_long';
