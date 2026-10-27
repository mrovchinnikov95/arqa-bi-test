-- Правила классификации кредита — в одном месте: пороги PAR, NPL, ставка провизий, класс риска.
-- Витрина и проверки вызывают эти функции, поэтому граничные случаи
-- (ровно 30 и ровно 90 дней, реструктуризация с малой просрочкой)
-- проверяются в sql/90_checks.sql на тех же функциях, что считают метрики.
--
-- Определения из задания и как они прочитаны:
--   PAR30  — просрочка больше 30 дней:  days_past_due > 30 (31+);
--   PAR90  — просрочка больше 90 дней:  days_past_due > 90 (91+);
--   NPL    — days_past_due > 90 ИЛИ реструктуризирован;
--   ставка провизий: NPL — 50 %, иначе 31–90 дней — 10 %, иначе 0–30 дней — 1 %.
--   Категории провизий не пересекаются: NPL проверяется первым, поэтому
--   реструктуризированный кредит с просрочкой 0–90 дней получает 50 %.
-- Некорректный вход (NULL или отрицательная просрочка) даёт NULL,
-- а не «тихую» категорию: такие строки ловят проверки на NOT NULL.

-- Пороги просрочки. Единственное место, где записаны 30 и 90 дней.
CREATE OR REPLACE FUNCTION reporting.is_par30(p_days_past_due integer)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE WHEN p_days_past_due IS NULL OR p_days_past_due < 0 THEN NULL ELSE p_days_past_due > 30 END
$$;

CREATE OR REPLACE FUNCTION reporting.is_par90(p_days_past_due integer)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE WHEN p_days_past_due IS NULL OR p_days_past_due < 0 THEN NULL ELSE p_days_past_due > 90 END
$$;

-- Корзина просрочки для разрезов: '0', '1–30', '31–90', '91+'.
CREATE OR REPLACE FUNCTION reporting.dpd_bucket(p_days_past_due integer)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE
        WHEN reporting.is_par30(p_days_past_due) IS NULL THEN NULL
        WHEN reporting.is_par90(p_days_past_due) THEN '91+'
        WHEN reporting.is_par30(p_days_past_due) THEN '31–90'
        WHEN p_days_past_due > 0 THEN '1–30'
        ELSE '0'
    END
$$;

CREATE OR REPLACE FUNCTION reporting.is_npl(p_days_past_due integer, p_restructured boolean)
RETURNS boolean
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE
        WHEN reporting.is_par90(p_days_past_due) IS NULL OR p_restructured IS NULL THEN NULL
        ELSE reporting.is_par90(p_days_past_due) OR p_restructured
    END
$$;

CREATE OR REPLACE FUNCTION reporting.provision_rate(p_days_past_due integer, p_restructured boolean)
RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE
        WHEN reporting.is_npl(p_days_past_due, p_restructured) IS NULL THEN NULL
        WHEN reporting.is_npl(p_days_past_due, p_restructured) THEN 0.50
        WHEN reporting.is_par30(p_days_past_due) THEN 0.10
        ELSE 0.01
    END
$$;

-- Класс риска для структуры портфеля: взаимоисключающие группы,
-- в сумме дают весь портфель. Реструктуризированный кредит с просрочкой
-- до 90 дней выделен отдельно, потому что он в NPL только из-за реструктуризации.
CREATE OR REPLACE FUNCTION reporting.risk_class(p_days_past_due integer, p_restructured boolean)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE
        WHEN reporting.is_npl(p_days_past_due, p_restructured) IS NULL THEN NULL
        WHEN reporting.is_par90(p_days_past_due) THEN 'NPL: просрочка 90+'
        WHEN p_restructured                      THEN 'NPL: реструктуризация'
        WHEN reporting.is_par30(p_days_past_due) THEN 'Просрочка 31–90'
        WHEN p_days_past_due > 0                 THEN 'Просрочка 1–30'
        ELSE 'Без просрочки'
    END
$$;

COMMENT ON FUNCTION reporting.is_par30(integer) IS 'PAR30: просрочка больше 30 дней (с 31-го)';
COMMENT ON FUNCTION reporting.is_par90(integer) IS 'PAR90: просрочка больше 90 дней (с 91-го)';
COMMENT ON FUNCTION reporting.dpd_bucket(integer) IS 'Корзина просрочки: 0, 1–30, 31–90, 91+';
COMMENT ON FUNCTION reporting.is_npl(integer, boolean) IS 'NPL: просрочка > 90 дней или реструктуризация';
COMMENT ON FUNCTION reporting.provision_rate(integer, boolean) IS 'Ставка провизий: NPL 50 %, 31–90 дней 10 %, 0–30 дней 1 %';
COMMENT ON FUNCTION reporting.risk_class(integer, boolean) IS 'Взаимоисключающий класс риска для структуры портфеля';
