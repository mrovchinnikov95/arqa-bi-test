-- Очищенная витрина.
--   v_fx_rates   — курсы с типами;
--   v_loans      — все кредиты обоих срезов после очистки, включая списанные (для аудита);
--   v_portfolio  — портфель: только несписанные кредиты; источник метрик и семантической модели.
-- Все суммы считаются в numeric без промежуточного округления: итоги сходятся до тиына,
-- округление — только при показе.

CREATE OR REPLACE VIEW reporting.v_fx_rates AS
SELECT
    trim(date)::date               AS rate_date,
    upper(trim(currency))          AS currency,
    trim(rate_kzt)::numeric        AS rate_kzt,
    source_line
FROM raw.fx;

COMMENT ON VIEW reporting.v_fx_rates IS 'Курс валюты к тенге на дату; KZT в файле нет, его курс = 1';

CREATE OR REPLACE VIEW reporting.v_loans AS
WITH typed AS (
    SELECT
        trim(report_date)::date                  AS report_date,
        trim(loan_id)                            AS loan_id,
        trim(borrower_id)                        AS borrower_id,
        trim(group_id)                           AS group_id,
        trim(sector)                             AS sector,
        trim(program)                            AS program,
        upper(trim(currency))                    AS currency,
        trim(issue_date)::date                   AS issue_date,
        trim(maturity_date)::date                AS maturity_date,
        trim(principal_outstanding)::numeric     AS principal_outstanding,
        trim(days_past_due)::integer             AS days_past_due,
        CASE trim(restructured) WHEN '1' THEN true WHEN '0' THEN false END AS is_restructured,
        CASE trim(written_off)  WHEN '1' THEN true WHEN '0' THEN false END AS is_written_off,
        source_line
    FROM raw.portfolio
),
-- В выгрузке есть строки-близнецы: полностью одинаковые записи одного кредита на одну дату.
-- Группировка по всем полям схлопывает только точные копии. Если у ключа
-- (report_date, loan_id) окажутся разные версии, они останутся двумя строками,
-- и проверка уникальности ключа в sql/90_checks.sql остановит сборку.
dedup AS (
    SELECT
        report_date, loan_id, borrower_id, group_id, sector, program, currency,
        issue_date, maturity_date, principal_outstanding, days_past_due,
        is_restructured, is_written_off,
        count(*)                                  AS source_rows,
        array_agg(source_line ORDER BY source_line) AS source_lines
    FROM typed
    GROUP BY
        report_date, loan_id, borrower_id, group_id, sector, program, currency,
        issue_date, maturity_date, principal_outstanding, days_past_due,
        is_restructured, is_written_off
),
priced AS (
    SELECT
        d.*,
        -- Курс строго на дату среза, без «последнего доступного»: нет курса — сумма NULL,
        -- и проверка остановит сборку.
        CASE WHEN d.currency = 'KZT' THEN 1::numeric ELSE fx.rate_kzt END AS fx_rate_kzt
    FROM dedup d
    LEFT JOIN reporting.v_fx_rates fx
           ON fx.rate_date = d.report_date
          AND fx.currency  = d.currency
)
SELECT
    report_date,
    loan_id,
    borrower_id,
    group_id,
    sector,
    program,
    currency,
    issue_date,
    maturity_date,
    principal_outstanding,
    fx_rate_kzt,
    principal_outstanding * fx_rate_kzt                       AS amount_kzt,
    days_past_due,
    reporting.dpd_bucket(days_past_due)                       AS dpd_bucket,
    is_restructured,
    is_written_off,
    NOT is_written_off                                         AS in_portfolio,
    reporting.is_par30(days_past_due)                          AS is_par30,
    reporting.is_par90(days_past_due)                          AS is_par90,
    reporting.is_npl(days_past_due, is_restructured)           AS is_npl,
    reporting.risk_class(days_past_due, is_restructured)       AS risk_class,
    -- Провизии считаются только по портфелю: у списанного кредита их нет в этой модели.
    CASE WHEN NOT is_written_off
         THEN reporting.provision_rate(days_past_due, is_restructured) END AS provision_rate,
    CASE WHEN NOT is_written_off
         THEN principal_outstanding * fx_rate_kzt
              * reporting.provision_rate(days_past_due, is_restructured) END AS provision_kzt,
    maturity_date < report_date                                AS is_past_maturity,
    source_rows,
    source_lines
FROM priced;

COMMENT ON VIEW reporting.v_loans IS
    'Очищенные кредиты обоих срезов, ключ (report_date, loan_id): типы, без дублей, сумма в тенге по курсу на дату среза. Включает списанные — для метрик брать v_portfolio';

CREATE OR REPLACE VIEW reporting.v_portfolio AS
SELECT
    report_date,
    loan_id,
    borrower_id,
    group_id,
    sector,
    program,
    currency,
    issue_date,
    maturity_date,
    principal_outstanding,
    fx_rate_kzt,
    amount_kzt,
    days_past_due,
    dpd_bucket,
    is_restructured,
    is_par30,
    is_par90,
    is_npl,
    risk_class,
    provision_rate,
    provision_kzt,
    is_past_maturity,
    -- Аддитивные меры для семантического слоя: доля = сумма меры / сумма amount_kzt.
    CASE WHEN is_par30        THEN amount_kzt ELSE 0 END AS par30_amount_kzt,
    CASE WHEN is_par90        THEN amount_kzt ELSE 0 END AS par90_amount_kzt,
    CASE WHEN is_npl          THEN amount_kzt ELSE 0 END AS npl_amount_kzt,
    CASE WHEN is_restructured THEN amount_kzt ELSE 0 END AS restructured_amount_kzt
FROM reporting.v_loans
WHERE in_portfolio;

COMMENT ON VIEW reporting.v_portfolio IS
    'Кредитный портфель: несписанные кредиты на дату среза, ключ (report_date, loan_id). Источник метрик и семантической модели';
