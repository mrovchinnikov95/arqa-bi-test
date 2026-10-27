-- Метрики риска на каждую дату среза и изменение к предыдущему срезу
-- (в этих данных предыдущий срез для 01.10.2026 — 01.09.2026).
-- Доли хранятся долями (0.0870 = 8,70 %), изменения долей — в процентных пунктах.

-- Десять крупнейших групп связанных заёмщиков на каждую дату.
-- Состав топ-10 пересчитывается на каждую дату отдельно.
-- При равенстве сумм порядок фиксирует group_id; ничью на 10-м месте ловит проверка.
CREATE OR REPLACE VIEW reporting.v_top_groups AS
WITH by_group AS (
    SELECT
        report_date,
        group_id,
        count(*)                    AS loan_count,
        count(DISTINCT borrower_id) AS borrower_count,
        sum(amount_kzt)             AS amount_kzt,
        sum(par30_amount_kzt)       AS par30_amount_kzt,
        sum(npl_amount_kzt)         AS npl_amount_kzt,
        max(days_past_due)          AS max_days_past_due
    FROM reporting.v_portfolio
    GROUP BY report_date, group_id
),
ranked AS (
    SELECT
        b.*,
        row_number() OVER (PARTITION BY report_date ORDER BY amount_kzt DESC, group_id) AS group_rank,
        sum(amount_kzt) OVER (PARTITION BY report_date)                                  AS portfolio_kzt
    FROM by_group b
)
SELECT
    report_date,
    group_rank,
    group_id,
    loan_count,
    borrower_count,
    amount_kzt,
    amount_kzt / portfolio_kzt AS share_of_portfolio,
    sum(amount_kzt) OVER (PARTITION BY report_date ORDER BY group_rank) / portfolio_kzt AS cumulative_share,
    par30_amount_kzt,
    npl_amount_kzt,
    max_days_past_due
FROM ranked
WHERE group_rank <= 10;

COMMENT ON VIEW reporting.v_top_groups IS 'Топ-10 групп связанных заёмщиков (group_id) по портфелю на каждую дату';

-- Широкая таблица: одна строка на дату среза.
CREATE OR REPLACE VIEW reporting.v_risk_metrics AS
WITH base AS (
    SELECT
        report_date,
        count(*)                     AS loan_count,
        sum(amount_kzt)              AS portfolio_kzt,
        sum(par30_amount_kzt)        AS par30_kzt,
        sum(par90_amount_kzt)        AS par90_kzt,
        sum(npl_amount_kzt)          AS npl_kzt,
        sum(restructured_amount_kzt) AS restructured_kzt,
        sum(provision_kzt)           AS provisions_kzt
    FROM reporting.v_portfolio
    GROUP BY report_date
),
top10 AS (
    SELECT report_date, sum(amount_kzt) AS top10_groups_kzt
    FROM reporting.v_top_groups
    GROUP BY report_date
),
excluded AS (
    SELECT
        report_date,
        count(*)        FILTER (WHERE is_written_off) AS written_off_count,
        coalesce(sum(amount_kzt) FILTER (WHERE is_written_off), 0) AS written_off_kzt
    FROM reporting.v_loans
    GROUP BY report_date
),
m AS (
    SELECT
        b.report_date,
        b.loan_count,
        b.portfolio_kzt,
        b.par30_kzt,
        b.par30_kzt        / b.portfolio_kzt AS par30_share,
        b.par90_kzt,
        b.par90_kzt        / b.portfolio_kzt AS par90_share,
        b.npl_kzt,
        b.npl_kzt          / b.portfolio_kzt AS npl_share,
        b.restructured_kzt,
        b.restructured_kzt / b.portfolio_kzt AS restructured_share,
        b.provisions_kzt,
        b.provisions_kzt   / b.portfolio_kzt AS provisions_share,
        t.top10_groups_kzt,
        t.top10_groups_kzt / b.portfolio_kzt AS top10_share,
        e.written_off_count,
        e.written_off_kzt
    FROM base b
    JOIN top10 t    USING (report_date)
    JOIN excluded e USING (report_date)
)
SELECT
    m.*,
    lag(report_date)    OVER w                            AS prev_report_date,
    portfolio_kzt  - lag(portfolio_kzt)  OVER w           AS portfolio_chg_kzt,
    portfolio_kzt  / lag(portfolio_kzt)  OVER w - 1       AS portfolio_chg_rel,
    loan_count     - lag(loan_count)     OVER w           AS loan_count_chg,
    (par30_share   - lag(par30_share)    OVER w) * 100    AS par30_chg_pp,
    (par90_share   - lag(par90_share)    OVER w) * 100    AS par90_chg_pp,
    (npl_share     - lag(npl_share)      OVER w) * 100    AS npl_chg_pp,
    (top10_share   - lag(top10_share)    OVER w) * 100    AS top10_chg_pp,
    provisions_kzt - lag(provisions_kzt) OVER w           AS provisions_chg_kzt,
    provisions_kzt / lag(provisions_kzt) OVER w - 1       AS provisions_chg_rel
FROM m
WINDOW w AS (ORDER BY report_date);

COMMENT ON VIEW reporting.v_risk_metrics IS
    'Метрики риска: одна строка на дату среза, изменения — к предыдущему срезу (доли в п.п., суммы в тенге и в долях)';

-- Длинная таблица метрик: строка = метрика × дата. Для плиток и графика динамики.
CREATE OR REPLACE VIEW reporting.v_risk_metrics_long AS
SELECT
    m.report_date,
    m.prev_report_date,
    v.sort_order,
    v.metric_code,
    v.metric_label,
    v.unit,
    v.value,
    v.prev_value,
    v.value - v.prev_value                                         AS change_abs,
    CASE WHEN v.unit = 'kzt' THEN v.value / nullif(v.prev_value, 0) - 1 END AS change_rel,
    CASE WHEN v.unit = 'share' THEN (v.value - v.prev_value) * 100 END   AS change_pp,
    -- Подписи для текстов: README и плитки дашборда берут числа отсюда, а не набирают руками.
    CASE v.unit
        WHEN 'kzt'   THEN reporting.fmt_bn(v.value)
        WHEN 'share' THEN reporting.fmt_pct(v.value, 2)
        WHEN 'count' THEN reporting.fmt_num(v.value, 0)
    END                                                            AS value_display,
    CASE WHEN v.prev_value IS NULL THEN NULL
         WHEN v.unit = 'kzt'   THEN reporting.fmt_bn_signed(v.value - v.prev_value)
                                    || ' (' || reporting.fmt_pct_signed(v.value / v.prev_value - 1, 1) || ')'
         WHEN v.unit = 'share' THEN reporting.fmt_pp((v.value - v.prev_value) * 100)
         WHEN v.unit = 'count' THEN reporting.fmt_signed(v.value - v.prev_value, 0)
    END                                                            AS change_display,
    CASE WHEN v.unit = 'kzt' THEN reporting.fmt_num(v.value, 2) || ' ₸' END AS value_exact_display
FROM (
    SELECT
        r.*,
        lag(r.portfolio_kzt)  OVER w AS prev_portfolio_kzt,
        lag(r.par30_share)    OVER w AS prev_par30_share,
        lag(r.par90_share)    OVER w AS prev_par90_share,
        lag(r.npl_share)      OVER w AS prev_npl_share,
        lag(r.provisions_kzt) OVER w AS prev_provisions_kzt,
        lag(r.top10_share)    OVER w AS prev_top10_share,
        lag(r.loan_count)     OVER w AS prev_loan_count
    FROM reporting.v_risk_metrics r
    WINDOW w AS (ORDER BY r.report_date)
) m
CROSS JOIN LATERAL (
    VALUES
        (1, 'portfolio',  'Портфель',      'kzt',   m.portfolio_kzt,        m.prev_portfolio_kzt),
        (2, 'par30',      'PAR30',         'share', m.par30_share,          m.prev_par30_share),
        (3, 'par90',      'PAR90',         'share', m.par90_share,          m.prev_par90_share),
        (4, 'npl',        'NPL',           'share', m.npl_share,            m.prev_npl_share),
        (5, 'provisions', 'Провизии',      'kzt',   m.provisions_kzt,       m.prev_provisions_kzt),
        (6, 'top10',      'Топ-10 групп',  'share', m.top10_share,          m.prev_top10_share),
        (7, 'loans',      'Кредитов',      'count', m.loan_count::numeric,  m.prev_loan_count::numeric)
) AS v(sort_order, metric_code, metric_label, unit, value, prev_value);

COMMENT ON VIEW reporting.v_risk_metrics_long IS 'Метрики риска в длинном виде: метрика × дата, значение, прошлое значение и изменение';

-- Разрезы: отрасль, программа, валюта, класс риска. Одна строка = дата × разрез × значение.
CREATE OR REPLACE VIEW reporting.v_risk_by_dimension AS
WITH g AS (
    SELECT
        report_date,
        CASE
            WHEN grouping(sector)     = 0 THEN 'sector'
            WHEN grouping(program)    = 0 THEN 'program'
            WHEN grouping(currency)   = 0 THEN 'currency'
            WHEN grouping(risk_class) = 0 THEN 'risk_class'
        END AS dimension,
        CASE
            WHEN grouping(sector)     = 0 THEN sector
            WHEN grouping(program)    = 0 THEN program
            WHEN grouping(currency)   = 0 THEN currency
            WHEN grouping(risk_class) = 0 THEN risk_class
        END AS dimension_value,
        count(*)              AS loan_count,
        sum(amount_kzt)       AS portfolio_kzt,
        sum(par30_amount_kzt) AS par30_kzt,
        sum(par90_amount_kzt) AS par90_kzt,
        sum(npl_amount_kzt)   AS npl_kzt,
        sum(provision_kzt)    AS provisions_kzt
    FROM reporting.v_portfolio
    GROUP BY report_date, GROUPING SETS ((sector), (program), (currency), (risk_class))
),
s AS (
    SELECT
        g.*,
        portfolio_kzt / sum(portfolio_kzt) OVER (PARTITION BY report_date, dimension) AS share_of_portfolio,
        par30_kzt / portfolio_kzt AS par30_share,
        par90_kzt / portfolio_kzt AS par90_share,
        npl_kzt   / portfolio_kzt AS npl_share
    FROM g
)
SELECT
    s.*,
    lag(report_date)  OVER w                          AS prev_report_date,
    portfolio_kzt - lag(portfolio_kzt) OVER w         AS portfolio_chg_kzt,
    (par30_share - lag(par30_share) OVER w) * 100     AS par30_chg_pp,
    (par90_share - lag(par90_share) OVER w) * 100     AS par90_chg_pp,
    (npl_share   - lag(npl_share)   OVER w) * 100     AS npl_chg_pp
FROM s
WINDOW w AS (PARTITION BY dimension, dimension_value ORDER BY report_date);

COMMENT ON VIEW reporting.v_risk_by_dimension IS
    'Портфель и риск по разрезам (sector, program, currency, risk_class) на каждую дату и изменение к предыдущему срезу';
