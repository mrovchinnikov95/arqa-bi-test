-- Аналитика для риск-комитета и качество данных.
--   v_dpd_migration    — миграция кредитов между классами риска от среза к срезу;
--   v_portfolio_bridge — из чего сложилось изменение портфеля (погашения, курс, списания);
--   v_data_quality     — найденные в выгрузке аномалии и что с ними сделано.

-- Пары соседних срезов: (предыдущая дата, текущая дата).
CREATE OR REPLACE VIEW reporting.v_snapshot_pairs AS
SELECT prev_report_date, report_date
FROM (
    SELECT report_date, lag(report_date) OVER (ORDER BY report_date) AS prev_report_date
    FROM (SELECT DISTINCT report_date FROM reporting.v_loans) d
) x
WHERE prev_report_date IS NOT NULL;

COMMENT ON VIEW reporting.v_snapshot_pairs IS 'Соседние даты срезов: предыдущий и текущий';

-- Состояние каждого кредита на паре срезов. Кредит, которого нет в одном из срезов,
-- попадает сюда с пустой стороной (в этих данных таких нет: 2000 кредитов в обоих срезах).
CREATE OR REPLACE VIEW reporting.v_loan_pairs AS
WITH keys AS (
    SELECT DISTINCT loan_id FROM reporting.v_loans
)
SELECT
    p.prev_report_date,
    p.report_date,
    k.loan_id,
    f.loan_id IS NOT NULL                                              AS in_prev_snapshot,
    t.loan_id IS NOT NULL                                              AS in_curr_snapshot,
    CASE WHEN f.is_written_off THEN 'Списан' ELSE f.risk_class END     AS prev_state,
    CASE WHEN t.is_written_off THEN 'Списан' ELSE t.risk_class END     AS curr_state,
    f.in_portfolio                                                     AS prev_in_portfolio,
    t.in_portfolio                                                     AS curr_in_portfolio,
    f.days_past_due                                                    AS prev_days_past_due,
    t.days_past_due                                                    AS curr_days_past_due,
    f.principal_outstanding                                            AS prev_principal,
    t.principal_outstanding                                            AS curr_principal,
    f.fx_rate_kzt                                                      AS prev_fx_rate_kzt,
    t.fx_rate_kzt                                                      AS curr_fx_rate_kzt,
    f.amount_kzt                                                       AS prev_amount_kzt,
    t.amount_kzt                                                       AS curr_amount_kzt,
    coalesce(t.group_id, f.group_id)                                   AS group_id,
    coalesce(t.sector, f.sector)                                       AS sector,
    -- События между срезами — одно определение для качества данных и для выводов.
    f.risk_class = 'NPL: просрочка 90+' AND NOT f.is_written_off
        AND t.risk_class = 'Без просрочки' AND NOT t.is_written_off     AS is_cure_from_90plus,
    f.is_written_off AND NOT t.is_written_off                          AS is_write_off_reversal,
    NOT f.is_written_off AND NOT t.is_written_off
        AND NOT f.is_par30 AND t.is_par30                              AS is_new_par30
FROM reporting.v_snapshot_pairs p
CROSS JOIN keys k
LEFT JOIN reporting.v_loans f ON f.report_date = p.prev_report_date AND f.loan_id = k.loan_id
LEFT JOIN reporting.v_loans t ON t.report_date = p.report_date      AND t.loan_id = k.loan_id
WHERE f.loan_id IS NOT NULL OR t.loan_id IS NOT NULL;

COMMENT ON VIEW reporting.v_loan_pairs IS 'Кредит на двух соседних срезах: класс риска, просрочка, остаток и курс до и после';

CREATE OR REPLACE VIEW reporting.v_dpd_migration AS
WITH s(state, state_order) AS (
    VALUES ('Без просрочки', 1), ('Просрочка 1–30', 2), ('Просрочка 31–90', 3),
           ('NPL: просрочка 90+', 4), ('NPL: реструктуризация', 5), ('Списан', 6), ('Нет в срезе', 7)
)
SELECT
    lp.prev_report_date,
    lp.report_date,
    coalesce(lp.prev_state, 'Нет в срезе') AS from_state,
    fs.state_order                         AS from_order,
    coalesce(lp.curr_state, 'Нет в срезе') AS to_state,
    ts.state_order                         AS to_order,
    count(*)                               AS loan_count,
    sum(lp.prev_amount_kzt)                AS from_amount_kzt,
    sum(lp.curr_amount_kzt)                AS to_amount_kzt
FROM reporting.v_loan_pairs lp
LEFT JOIN s fs ON fs.state = coalesce(lp.prev_state, 'Нет в срезе')
LEFT JOIN s ts ON ts.state = coalesce(lp.curr_state, 'Нет в срезе')
GROUP BY lp.prev_report_date, lp.report_date, 3, 4, 5, 6;

COMMENT ON VIEW reporting.v_dpd_migration IS 'Матрица миграции: сколько кредитов и сколько тенге перешло из класса риска в класс между срезами';

-- Мост портфеля. Для кредита, который был в портфеле на обоих срезах:
--   P1·r1 − P0·r0 = (P1 − P0)·r1  +  P0·(r1 − r0)
--                   погашения        переоценка по курсу
-- Шаги в сумме дают ровно конечный портфель — это проверяется в sql/90_checks.sql.
CREATE OR REPLACE VIEW reporting.v_portfolio_bridge AS
WITH c AS (
    SELECT
        prev_report_date,
        report_date,
        coalesce(sum(prev_amount_kzt) FILTER (WHERE prev_in_portfolio), 0) AS start_kzt,
        coalesce(sum((curr_principal - prev_principal) * curr_fx_rate_kzt)
                 FILTER (WHERE prev_in_portfolio AND curr_in_portfolio), 0) AS repayment_kzt,
        coalesce(sum(prev_principal * (curr_fx_rate_kzt - prev_fx_rate_kzt))
                 FILTER (WHERE prev_in_portfolio AND curr_in_portfolio), 0) AS fx_kzt,
        coalesce(-sum(prev_amount_kzt)
                 FILTER (WHERE prev_in_portfolio AND curr_in_portfolio IS FALSE), 0) AS written_off_kzt,
        coalesce(-sum(prev_amount_kzt)
                 FILTER (WHERE prev_in_portfolio AND NOT in_curr_snapshot), 0) AS left_snapshot_kzt,
        coalesce(sum(curr_amount_kzt)
                 FILTER (WHERE prev_in_portfolio IS FALSE AND curr_in_portfolio), 0) AS returned_kzt,
        coalesce(sum(curr_amount_kzt)
                 FILTER (WHERE NOT in_prev_snapshot AND curr_in_portfolio), 0) AS new_kzt,
        coalesce(sum(curr_amount_kzt) FILTER (WHERE curr_in_portfolio), 0) AS end_kzt
    FROM reporting.v_loan_pairs
    GROUP BY prev_report_date, report_date
),
steps AS (
    SELECT c.prev_report_date, c.report_date, v.*
    FROM c
    CROSS JOIN LATERAL (
        VALUES
            (1, 'start',       'Портфель на начало',                 'total', c.start_kzt),
            (2, 'repayment',   'Погашения основного долга',          'delta', c.repayment_kzt),
            (3, 'fx',          'Переоценка USD по курсу',            'delta', c.fx_kzt),
            (4, 'written_off', 'Списаны за месяц',                   'delta', c.written_off_kzt),
            (5, 'returned',    'Вернулись из списанных',             'delta', c.returned_kzt),
            (6, 'new',         'Новые кредиты',                      'delta', c.new_kzt),
            (7, 'left',        'Выбыли из выгрузки',                 'delta', c.left_snapshot_kzt),
            (8, 'end',         'Портфель на конец',                  'total', c.end_kzt)
    ) AS v(step_order, step_code, step_label, step_kind, amount_kzt)
)
SELECT
    s.*,
    CASE WHEN step_kind = 'total' THEN 0
         ELSE sum(CASE WHEN step_kind = 'delta' OR step_code = 'start' THEN amount_kzt ELSE 0 END)
                  OVER w - amount_kzt
    END AS bar_start_kzt,
    CASE WHEN step_kind = 'total' THEN amount_kzt
         ELSE sum(CASE WHEN step_kind = 'delta' OR step_code = 'start' THEN amount_kzt ELSE 0 END) OVER w
    END AS bar_end_kzt
FROM steps s
WINDOW w AS (PARTITION BY report_date ORDER BY step_order ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW);

COMMENT ON VIEW reporting.v_portfolio_bridge IS
    'Мост портфеля между соседними срезами: начало, погашения, курс, списания, возвраты из списанных, конец';

CREATE OR REPLACE VIEW reporting.v_data_quality AS
WITH dup AS (
    SELECT report_date,
           count(*) FILTER (WHERE source_rows > 1) AS keys,
           coalesce(sum(source_rows - 1), 0)       AS extra_rows,
           coalesce(sum((source_rows - 1) * amount_kzt), 0) AS extra_amount_kzt
    FROM reporting.v_loans
    GROUP BY report_date
),
conflicts AS (
    SELECT d.report_date, count(x.loan_id) AS keys
    FROM (SELECT DISTINCT report_date FROM reporting.v_loans) d
    LEFT JOIN (
        SELECT report_date, loan_id FROM reporting.v_loans
        GROUP BY report_date, loan_id HAVING count(*) > 1
    ) x USING (report_date)
    GROUP BY d.report_date
),
per_date AS (
    SELECT
        report_date,
        count(*) FILTER (WHERE amount_kzt IS NULL)                         AS missing_fx_rows,
        count(*) FILTER (WHERE principal_outstanding <= 0)                  AS non_positive_rows,
        count(*) FILTER (WHERE is_written_off)                              AS written_off_rows,
        coalesce(sum(amount_kzt) FILTER (WHERE is_written_off), 0)          AS written_off_kzt,
        count(*) FILTER (WHERE in_portfolio AND is_past_maturity AND days_past_due = 0) AS past_maturity_rows,
        coalesce(sum(amount_kzt) FILTER (WHERE in_portfolio AND is_past_maturity AND days_past_due = 0), 0) AS past_maturity_kzt,
        count(*) FILTER (WHERE is_written_off AND is_restructured)          AS restructured_written_off_rows
    FROM reporting.v_loans
    GROUP BY report_date
),
pairs AS (
    SELECT
        report_date,
        count(*) FILTER (WHERE is_write_off_reversal)                             AS reversal_rows,
        coalesce(sum(curr_amount_kzt) FILTER (WHERE is_write_off_reversal), 0)    AS reversal_kzt,
        count(*) FILTER (WHERE is_cure_from_90plus)                               AS cure_90_rows,
        coalesce(sum(curr_amount_kzt) FILTER (WHERE is_cure_from_90plus), 0)      AS cure_90_kzt,
        count(*) FILTER (WHERE curr_days_past_due - prev_days_past_due > report_date - prev_report_date) AS dpd_jump_rows
    FROM reporting.v_loan_pairs
    GROUP BY report_date
)
SELECT d.report_date, v.*
FROM per_date d
JOIN dup       USING (report_date)
JOIN conflicts c USING (report_date)
LEFT JOIN pairs p USING (report_date)
CROSS JOIN LATERAL (
    VALUES
        (1, 'duplicate_rows', 'warning', 'Полные дубли строк (кредит повторён на ту же дату)',
            dup.extra_rows, dup.extra_amount_kzt, 'Схлопнуты в одну строку'),
        (2, 'conflicting_versions', 'error', 'Разные версии одного кредита на одну дату',
            c.keys::bigint, NULL::numeric, 'Сборка останавливается'),
        (3, 'missing_fx', 'error', 'Нет курса на дату среза',
            d.missing_fx_rows, NULL, 'Сборка останавливается'),
        (4, 'non_positive_principal', 'error', 'Остаток ≤ 0',
            d.non_positive_rows, NULL, 'Сборка останавливается'),
        (5, 'written_off', 'info', 'Списанные кредиты',
            d.written_off_rows, d.written_off_kzt, 'Исключены из портфеля и всех метрик'),
        (6, 'write_off_reversal', 'warning', 'Были списаны на прошлом срезе, на этом снова в портфеле',
            p.reversal_rows, p.reversal_kzt, 'В портфеле по флагу текущего среза; вопрос владельцу данных'),
        (7, 'cure_from_90plus', 'warning', 'Просрочка 90+ на прошлом срезе, без просрочки на этом',
            p.cure_90_rows, p.cure_90_kzt, 'Учтены как есть; подтвердить погашения'),
        (8, 'past_maturity_zero_dpd', 'warning', 'Срок погашения прошёл, остаток есть, просрочка 0 дней',
            d.past_maturity_rows, d.past_maturity_kzt, 'Учтены как есть; просрочка может быть занижена'),
        (9, 'dpd_jump', 'error', 'Просрочка выросла больше, чем прошло дней между срезами',
            p.dpd_jump_rows, NULL, 'Сборка останавливается'),
        (10, 'restructured_written_off', 'info', 'Реструктуризированные среди списанных (вне NPL)',
            d.restructured_written_off_rows, NULL, 'Вне портфеля, как все списанные')
) AS v(check_order, check_code, severity, check_title, row_count, amount_kzt, handling);

COMMENT ON VIEW reporting.v_data_quality IS 'Аномалии выгрузки по датам: сколько строк, на какую сумму и как обработаны';
