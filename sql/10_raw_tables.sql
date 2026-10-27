-- Таблицы слоя raw.
-- Все поля из файла хранятся текстом: загрузка не падает и ничего не округляет,
-- а приведение типов и проверки живут в reporting и в sql/90_checks.sql.
-- source_line — номер строки данных в файле (1 = первая строка после заголовка),
-- чтобы любую аномалию можно было найти в исходном CSV.

CREATE TABLE IF NOT EXISTS raw.portfolio (
    source_line           bigint GENERATED ALWAYS AS IDENTITY,
    report_date           text,
    loan_id               text,
    borrower_id           text,
    group_id              text,
    sector                text,
    program               text,
    currency              text,
    issue_date            text,
    maturity_date         text,
    principal_outstanding text,
    days_past_due         text,
    restructured          text,
    written_off           text
);

COMMENT ON TABLE raw.portfolio IS 'portfolio.csv как есть: два месячных среза кредитного портфеля';
COMMENT ON COLUMN raw.portfolio.principal_outstanding IS 'Остаток основного долга в валюте кредита';

CREATE TABLE IF NOT EXISTS raw.fx (
    source_line bigint GENERATED ALWAYS AS IDENTITY,
    date        text,
    currency    text,
    rate_kzt    text
);

COMMENT ON TABLE raw.fx IS 'fx.csv как есть: курс валюты к тенге по дням';
