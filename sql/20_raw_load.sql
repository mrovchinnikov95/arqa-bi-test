-- Загрузка CSV в raw. Запускать из корня репозитория (пути относительные).
-- Полная перезаливка в одной транзакции: повторный запуск даёт те же строки
-- и те же source_line, а при ошибке остаются прежние данные.
-- HEADER MATCH (PostgreSQL 15+) падает, если в файле поменялись колонки.

BEGIN;

TRUNCATE raw.portfolio RESTART IDENTITY;
\copy raw.portfolio (report_date, loan_id, borrower_id, group_id, sector, program, currency, issue_date, maturity_date, principal_outstanding, days_past_due, restructured, written_off) FROM 'data/portfolio.csv' WITH (FORMAT csv, HEADER match, ENCODING 'UTF8')

TRUNCATE raw.fx RESTART IDENTITY;
\copy raw.fx (date, currency, rate_kzt) FROM 'data/fx.csv' WITH (FORMAT csv, HEADER match, ENCODING 'UTF8')

COMMIT;
