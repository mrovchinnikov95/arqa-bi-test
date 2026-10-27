-- Проверки сборки. Каждая проверка пишет строку в check_results; в конце, если хоть одна
-- не прошла, скрипт падает с ошибкой (psql -v ON_ERROR_STOP=1 вернёт код 3).
-- Сначала проверяется сырьё (иначе приведение типов во вьюхах упадёт с невнятной ошибкой),
-- потом витрина, инварианты метрик и граничные случаи определений.
-- pg_input_is_valid() есть с PostgreSQL 16.

\set QUIET on
CREATE TEMP TABLE check_results (
    check_no   serial,
    check_name text,
    ok         boolean,
    detail     text
);

-- ---------- 1. Сырьё: raw.portfolio ----------
INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.portfolio не пустая', count(*) > 0, count(*) || ' строк' FROM raw.portfolio;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.portfolio: ключевые поля заполнены',
       count(*) = 0, count(*) || ' строк с пустым полем'
FROM raw.portfolio
WHERE coalesce(trim(report_date), '') = '' OR coalesce(trim(loan_id), '') = ''
   OR coalesce(trim(borrower_id), '') = '' OR coalesce(trim(group_id), '') = ''
   OR coalesce(trim(sector), '') = '' OR coalesce(trim(program), '') = ''
   OR coalesce(trim(currency), '') = '' OR coalesce(trim(issue_date), '') = ''
   OR coalesce(trim(maturity_date), '') = '' OR coalesce(trim(principal_outstanding), '') = ''
   OR coalesce(trim(days_past_due), '') = '' OR coalesce(trim(restructured), '') = ''
   OR coalesce(trim(written_off), '') = '';

INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.portfolio: даты читаются как date',
       count(*) = 0, count(*) || ' строк с некорректной датой'
FROM raw.portfolio
WHERE NOT pg_input_is_valid(trim(report_date), 'date')
   OR NOT pg_input_is_valid(trim(issue_date), 'date')
   OR NOT pg_input_is_valid(trim(maturity_date), 'date')
   OR trim(report_date) !~ '^\d{4}-\d{2}-\d{2}$';

INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.portfolio: остаток — число с не более чем 2 знаками после точки',
       count(*) = 0, count(*) || ' строк'
FROM raw.portfolio
WHERE trim(principal_outstanding) !~ '^-?\d+(\.\d{1,2})?$';

INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.portfolio: остаток > 0 (нет нулевых и отрицательных)',
       count(*) = 0, count(*) || ' строк'
FROM raw.portfolio
WHERE CASE WHEN trim(principal_outstanding) ~ '^-?\d+(\.\d{1,2})?$'
           THEN trim(principal_outstanding)::numeric <= 0 ELSE false END;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.portfolio: просрочка — целое число ≥ 0',
       count(*) = 0, count(*) || ' строк'
FROM raw.portfolio
WHERE trim(days_past_due) !~ '^\d+$';

INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.portfolio: флаги restructured и written_off только 0 или 1',
       count(*) = 0, count(*) || ' строк'
FROM raw.portfolio
WHERE trim(restructured) NOT IN ('0', '1') OR trim(written_off) NOT IN ('0', '1');

INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.portfolio: выдача не позже даты среза и не позже срока погашения',
       count(*) = 0, count(*) || ' строк'
FROM raw.portfolio
WHERE CASE WHEN pg_input_is_valid(trim(issue_date), 'date') AND pg_input_is_valid(trim(maturity_date), 'date')
                AND pg_input_is_valid(trim(report_date), 'date')
           THEN trim(issue_date)::date > trim(report_date)::date OR trim(issue_date)::date > trim(maturity_date)::date
           ELSE false END;

-- ---------- 2. Сырьё: raw.fx ----------
INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.fx не пустая', count(*) > 0, count(*) || ' строк' FROM raw.fx;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.fx: дата и курс корректны, курс > 0',
       count(*) = 0, count(*) || ' строк'
FROM raw.fx
WHERE coalesce(trim(currency), '') = ''
   OR NOT coalesce(pg_input_is_valid(trim(date), 'date'), false)
   OR CASE WHEN trim(rate_kzt) ~ '^\d+(\.\d+)?$' THEN trim(rate_kzt)::numeric <= 0 ELSE true END;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'raw.fx: один курс на (дату, валюту)',
       count(*) = 0, count(*) || ' повторов'
FROM (SELECT trim(date), upper(trim(currency)) FROM raw.fx GROUP BY 1, 2 HAVING count(*) > 1) d;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Курс есть на каждую дату среза для каждой валюты портфеля, кроме KZT',
       count(*) = 0,
       coalesce(string_agg(p.report_date || ' ' || p.currency, ', '), 'все пары есть')
FROM (SELECT DISTINCT trim(report_date) AS report_date, upper(trim(currency)) AS currency
      FROM raw.portfolio WHERE upper(trim(currency)) <> 'KZT') p
LEFT JOIN raw.fx f
       ON trim(f.date) = p.report_date AND upper(trim(f.currency)) = p.currency
WHERE f.rate_kzt IS NULL;

-- Если сырьё сломано, дальше проверять бессмысленно: вьюхи упадут на приведении типов.
SELECT count(*) FILTER (WHERE ok IS DISTINCT FROM true) > 0 AS raw_failed FROM check_results \gset
\if :raw_failed
    \set QUIET off
    SELECT check_no AS "№", CASE WHEN ok THEN 'ok' ELSE 'FAIL' END AS "итог", check_name AS "проверка", detail AS "детали"
    FROM check_results ORDER BY check_no;
    DO $$ BEGIN RAISE EXCEPTION 'ОСТАНОВКА: сырьё не прошло проверки, витрину не проверяю'; END $$;
\endif

-- ---------- 3. Очищенная витрина ----------
INSERT INTO check_results (check_name, ok, detail)
SELECT 'v_loans: ключ (report_date, loan_id) уникален — разных версий одного кредита нет',
       count(*) = 0, count(*) || ' ключей с несколькими версиями'
FROM (SELECT report_date, loan_id FROM reporting.v_loans GROUP BY 1, 2 HAVING count(*) > 1) d;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'v_loans: все строки raw учтены (сумма source_rows = строк в raw)',
       (SELECT sum(source_rows) FROM reporting.v_loans) = (SELECT count(*) FROM raw.portfolio),
       (SELECT sum(source_rows) FROM reporting.v_loans) || ' против ' || (SELECT count(*) FROM raw.portfolio);

INSERT INTO check_results (check_name, ok, detail)
SELECT 'v_loans: строк столько же, сколько различных строк в raw',
       (SELECT count(*) FROM reporting.v_loans)
     = (SELECT count(*) FROM (SELECT DISTINCT report_date, loan_id, borrower_id, group_id, sector, program,
                                     currency, issue_date, maturity_date, principal_outstanding,
                                     days_past_due, restructured, written_off FROM raw.portfolio) d),
       (SELECT count(*) FROM reporting.v_loans) || ' строк в v_loans';

INSERT INTO check_results (check_name, ok, detail)
SELECT 'v_loans: остаток в валюте кредита сходится с raw по дате и валюте (без дублей)',
       count(*) = 0, coalesce(string_agg(report_date || ' ' || currency, ', '), 'сходится')
FROM (
    SELECT report_date::date AS report_date, upper(currency) AS currency, sum(principal_outstanding::numeric) AS s
    FROM (SELECT DISTINCT report_date, loan_id, borrower_id, group_id, sector, program, currency, issue_date,
                          maturity_date, principal_outstanding, days_past_due, restructured, written_off
          FROM raw.portfolio) r
    GROUP BY 1, 2
) r
FULL JOIN (
    SELECT report_date, currency, sum(principal_outstanding) AS s FROM reporting.v_loans GROUP BY 1, 2
) v USING (report_date, currency)
WHERE r.s IS DISTINCT FROM v.s;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'v_loans: нет NULL в типизированных и расчётных полях',
       count(*) = 0, count(*) || ' строк'
FROM reporting.v_loans
WHERE report_date IS NULL OR loan_id IS NULL OR borrower_id IS NULL OR group_id IS NULL
   OR sector IS NULL OR program IS NULL OR currency IS NULL OR issue_date IS NULL
   OR maturity_date IS NULL OR principal_outstanding IS NULL OR fx_rate_kzt IS NULL
   OR amount_kzt IS NULL OR days_past_due IS NULL OR dpd_bucket IS NULL
   OR is_restructured IS NULL OR is_written_off IS NULL OR is_npl IS NULL OR risk_class IS NULL
   OR (in_portfolio AND (provision_rate IS NULL OR provision_kzt IS NULL));

INSERT INTO check_results (check_name, ok, detail)
SELECT 'v_loans: каждый заёмщик входит ровно в одну группу',
       count(*) = 0, count(*) || ' заёмщиков в нескольких группах'
FROM (SELECT borrower_id FROM reporting.v_loans GROUP BY 1 HAVING count(DISTINCT group_id) > 1) d;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'v_portfolio = v_loans без списанных; портфель + списанные = все кредиты',
       (SELECT count(*) FROM reporting.v_portfolio)
         + (SELECT count(*) FROM reporting.v_loans WHERE is_written_off)
         = (SELECT count(*) FROM reporting.v_loans)
       AND (SELECT sum(amount_kzt) FROM reporting.v_portfolio)
         + (SELECT coalesce(sum(amount_kzt), 0) FROM reporting.v_loans WHERE is_written_off)
         = (SELECT sum(amount_kzt) FROM reporting.v_loans),
       (SELECT count(*) FROM reporting.v_portfolio) || ' кредитов в портфеле за обе даты';

-- ---------- 4. Граничные случаи определений: функции правил на синтетических входах ----------
INSERT INTO check_results (check_name, ok, detail)
SELECT 'Правила: ' || t.case_name,
       reporting.is_par30(t.dpd)                IS NOT DISTINCT FROM t.exp_par30
   AND reporting.is_par90(t.dpd)                IS NOT DISTINCT FROM t.exp_par90
   AND reporting.dpd_bucket(t.dpd)              IS NOT DISTINCT FROM t.exp_bucket
   AND reporting.is_npl(t.dpd, t.restr)         IS NOT DISTINCT FROM t.exp_npl
   AND reporting.provision_rate(t.dpd, t.restr) IS NOT DISTINCT FROM t.exp_rate
   AND reporting.risk_class(t.dpd, t.restr)     IS NOT DISTINCT FROM t.exp_class,
       format('par30=%s par90=%s bucket=%s npl=%s rate=%s class=%s',
              reporting.is_par30(t.dpd), reporting.is_par90(t.dpd), reporting.dpd_bucket(t.dpd),
              reporting.is_npl(t.dpd, t.restr), reporting.provision_rate(t.dpd, t.restr),
              reporting.risk_class(t.dpd, t.restr))
FROM (VALUES
    -- случай                                           dpd  restr  PAR30  PAR90  корзина  NPL    ставка класс
    ('0 дней → 1 %, не PAR, не NPL',                     0,   false, false, false, '0',     false, 0.01, 'Без просрочки'),
    ('1 день → 1 %',                                     1,   false, false, false, '1–30',  false, 0.01, 'Просрочка 1–30'),
    ('ровно 30 дней → ещё не PAR30, 1 %',                30,  false, false, false, '1–30',  false, 0.01, 'Просрочка 1–30'),
    ('31 день → PAR30, 10 %',                            31,  false, true,  false, '31–90', false, 0.10, 'Просрочка 31–90'),
    ('ровно 90 дней → PAR30, ещё не PAR90 и не NPL, 10 %', 90, false, true,  false, '31–90', false, 0.10, 'Просрочка 31–90'),
    ('91 день → PAR90, NPL, 50 %',                       91,  false, true,  true,  '91+',   true,  0.50, 'NPL: просрочка 90+'),
    ('реструктуризация, 0 дней → NPL, 50 %, не PAR',     0,   true,  false, false, '0',     true,  0.50, 'NPL: реструктуризация'),
    ('реструктуризация, 5 дней → NPL, 50 %',             5,   true,  false, false, '1–30',  true,  0.50, 'NPL: реструктуризация'),
    ('реструктуризация, 45 дней → NPL, 50 %, не 10 %',   45,  true,  true,  false, '31–90', true,  0.50, 'NPL: реструктуризация'),
    ('реструктуризация и 120 дней → NPL один раз',       120, true,  true,  true,  '91+',   true,  0.50, 'NPL: просрочка 90+'),
    ('отрицательная просрочка → NULL, не 1 %',           -1,  false, NULL,  NULL,  NULL,    NULL,  NULL, NULL),
    ('просрочка NULL → NULL',                            NULL, false, NULL, NULL,  NULL,    NULL,  NULL, NULL),
    ('флаг реструктуризации NULL → NULL',                10,  NULL,  false, false, '1–30',  NULL,  NULL, NULL)
) AS t(case_name, dpd, restr, exp_par30, exp_par90, exp_bucket, exp_npl, exp_rate, exp_class);

-- ---------- 5. Граничные случаи на реальных строках: проверка не пустая, если строки есть ----------
INSERT INTO check_results (check_name, ok, detail)
SELECT 'Данные: граничные строки (30, 31, 90, 91 день) в выгрузке есть — тесты ниже не пустые',
       bool_and(n > 0), string_agg(dpd || ' дн.: ' || n, ', ' ORDER BY dpd)
FROM (SELECT d.dpd, count(p.loan_id) AS n
      FROM (VALUES (30), (31), (90), (91)) d(dpd)
      LEFT JOIN reporting.v_portfolio p ON p.days_past_due = d.dpd
      GROUP BY d.dpd) x;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Данные: PAR30 начинается с 31 дня, PAR90 — с 91 дня (сверка флагов витрины с порогом, записанным здесь отдельно)',
       count(*) = 0, count(*) || ' строк с неверным флагом'
FROM reporting.v_portfolio
WHERE is_par30 IS DISTINCT FROM (days_past_due >= 31) OR is_par90 IS DISTINCT FROM (days_past_due >= 91);

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Данные: реструктуризированный кредит всегда NPL со ставкой 50 % (в т.ч. с малой просрочкой)',
       count(*) FILTER (WHERE NOT is_npl OR provision_rate <> 0.50) = 0
   AND count(*) FILTER (WHERE days_past_due <= 30) > 0,
       count(*) || ' реструктуризированных, из них с просрочкой ≤ 30 дней: '
         || count(*) FILTER (WHERE days_past_due <= 30)
FROM reporting.v_portfolio
WHERE is_restructured;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Данные: каждый кредит портфеля получил ровно одну ставку провизий из {1 %, 10 %, 50 %}',
       count(*) FILTER (WHERE provision_rate NOT IN (0.01, 0.10, 0.50) OR provision_rate IS NULL) = 0,
       string_agg(DISTINCT provision_rate::text, ', ')
FROM reporting.v_portfolio;

-- ---------- 6. Инварианты метрик ----------
INSERT INTO check_results (check_name, ok, detail)
SELECT 'Метрики: PAR90 ≤ PAR30 ≤ портфель, PAR90 ≤ NPL ≤ портфель, доли в [0; 1]',
       bool_and(par90_kzt <= par30_kzt AND par30_kzt <= portfolio_kzt
                AND par90_kzt <= npl_kzt AND npl_kzt <= portfolio_kzt
                AND top10_share BETWEEN 0 AND 1 AND provisions_kzt <= portfolio_kzt),
       string_agg(report_date::text, ', ')
FROM reporting.v_risk_metrics;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Метрики: NPL = PAR90 + реструктуризированные с просрочкой ≤ 90 (без двойного счёта)',
       bool_and(m.npl_kzt = m.par90_kzt + x.restr_le90),
       string_agg(m.report_date || ': ' || m.npl_kzt || ' = ' || m.par90_kzt || ' + ' || x.restr_le90, '; ')
FROM reporting.v_risk_metrics m
JOIN (SELECT report_date,
             coalesce(sum(amount_kzt) FILTER (WHERE is_restructured AND days_past_due <= 90), 0) AS restr_le90
      FROM reporting.v_portfolio GROUP BY 1) x USING (report_date);

-- Провизии второй раз, отдельным выражением, не через функцию provision_rate().
INSERT INTO check_results (check_name, ok, detail)
SELECT 'Метрики: провизии = 1 % × (0–30) + 10 % × (31–90) + 50 % × NPL',
       bool_and(m.provisions_kzt = x.expected),
       string_agg(m.report_date || ': ' || m.provisions_kzt || ' против ' || x.expected, '; ')
FROM reporting.v_risk_metrics m
JOIN (SELECT report_date,
             0.01 * coalesce(sum(amount_kzt) FILTER (WHERE days_past_due <= 30 AND NOT is_restructured), 0)
           + 0.10 * coalesce(sum(amount_kzt) FILTER (WHERE days_past_due BETWEEN 31 AND 90 AND NOT is_restructured), 0)
           + 0.50 * coalesce(sum(amount_kzt) FILTER (WHERE days_past_due > 90 OR is_restructured), 0) AS expected
      FROM reporting.v_portfolio GROUP BY 1) x USING (report_date);

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Разрезы: по каждому разрезу сумма значений = портфель на дату',
       count(*) = 0, coalesce(string_agg(report_date || ' ' || dimension, ', '), 'сходится')
FROM (SELECT report_date, dimension, sum(portfolio_kzt) AS s, sum(loan_count) AS n,
             sum(npl_kzt) AS npl, sum(provisions_kzt) AS prov
      FROM reporting.v_risk_by_dimension GROUP BY 1, 2) d
JOIN reporting.v_risk_metrics m USING (report_date)
WHERE d.s <> m.portfolio_kzt OR d.n <> m.loan_count OR d.npl <> m.npl_kzt OR d.prov <> m.provisions_kzt;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Концентрация: ровно 10 групп на дату и нет ничьей между 10-й и 11-й группой',
       bool_and(top_n = 10 AND tenth > eleventh),
       string_agg(report_date || ': 10-я ' || tenth || ', 11-я ' || eleventh, '; ')
FROM (
    SELECT report_date,
           count(*) FILTER (WHERE rn <= 10) AS top_n,
           max(amt) FILTER (WHERE rn = 10)  AS tenth,
           max(amt) FILTER (WHERE rn = 11)  AS eleventh
    FROM (SELECT report_date, group_id, sum(amount_kzt) AS amt,
                 row_number() OVER (PARTITION BY report_date ORDER BY sum(amount_kzt) DESC, group_id) AS rn
          FROM reporting.v_portfolio GROUP BY 1, 2) g
    GROUP BY report_date
) x;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Концентрация считается по group_id, а не по borrower_id (группы объединяют заёмщиков)',
       (SELECT count(*) FROM reporting.v_top_groups WHERE borrower_count > 1) > 0,
       (SELECT count(*) FROM reporting.v_top_groups WHERE borrower_count > 1) || ' строк топ-10 с несколькими заёмщиками';

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Мост портфеля: начало + шаги = конец, начало и конец = портфель на даты',
       bool_and(b.calc_end = b.end_kzt AND b.start_kzt = mp.portfolio_kzt AND b.end_kzt = mc.portfolio_kzt),
       string_agg(b.report_date || ': ' || b.calc_end || ' = ' || b.end_kzt, '; ')
FROM (SELECT prev_report_date, report_date,
             sum(amount_kzt) FILTER (WHERE step_code <> 'end') AS calc_end,
             max(amount_kzt) FILTER (WHERE step_code = 'start') AS start_kzt,
             max(amount_kzt) FILTER (WHERE step_code = 'end')   AS end_kzt
      FROM reporting.v_portfolio_bridge GROUP BY 1, 2) b
JOIN reporting.v_risk_metrics mp ON mp.report_date = b.prev_report_date
JOIN reporting.v_risk_metrics mc ON mc.report_date = b.report_date;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Миграция: суммы по классам на начало и на конец = портфель на даты',
       bool_and(x.from_portfolio = mp.portfolio_kzt AND x.to_portfolio = mc.portfolio_kzt),
       string_agg(x.report_date::text, ', ')
FROM (SELECT prev_report_date, report_date,
             sum(from_amount_kzt) FILTER (WHERE from_state NOT IN ('Списан', 'Нет в срезе')) AS from_portfolio,
             sum(to_amount_kzt)   FILTER (WHERE to_state   NOT IN ('Списан', 'Нет в срезе')) AS to_portfolio
      FROM reporting.v_dpd_migration GROUP BY 1, 2) x
JOIN reporting.v_risk_metrics mp ON mp.report_date = x.prev_report_date
JOIN reporting.v_risk_metrics mc ON mc.report_date = x.report_date;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Качество данных: блокирующих аномалий нет (severity = error → 0 строк)',
       coalesce(sum(row_count) FILTER (WHERE severity = 'error'), 0) = 0,
       coalesce(string_agg(check_code || '=' || row_count, ', ') FILTER (WHERE severity = 'error' AND row_count > 0), 'нет')
FROM reporting.v_data_quality;

INSERT INTO check_results (check_name, ok, detail)
SELECT 'Факты для README: все посчитаны (нет пустых значений и подписей)',
       count(*) FILTER (WHERE display IS NULL OR (value IS NULL AND fact_code NOT IN
                        ('new_par30_group', 'new_par30_loan', 'new_par30_sector'))) = 0 AND count(*) > 0,
       count(*) || ' фактов, пустых: ' || count(*) FILTER (WHERE display IS NULL)
FROM reporting.v_committee_facts;

-- ---------- Итог ----------
\set QUIET off
SELECT check_no AS "№", CASE WHEN ok THEN 'ok' ELSE 'FAIL' END AS "итог", check_name AS "проверка", detail AS "детали"
FROM check_results ORDER BY check_no;

SELECT count(*) FILTER (WHERE ok IS DISTINCT FROM true) AS failed, count(*) AS total,
       count(*) FILTER (WHERE ok IS DISTINCT FROM true) > 0 AS any_failed
FROM check_results \gset
\echo 'Проверок:' :total ', не прошло:' :failed
\if :any_failed
    DO $$ BEGIN RAISE EXCEPTION 'ОСТАНОВКА: есть непрошедшие проверки'; END $$;
\endif
