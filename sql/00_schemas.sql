-- Схемы проекта.
--   raw       — данные как в CSV, без преобразований (все поля текстом);
--   reporting — очищенная витрина и метрики (только вьюхи и функции).
-- Повторный запуск безопасен.

CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS reporting;
