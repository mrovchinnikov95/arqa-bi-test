-- Форматирование чисел для текстов (README, подписи): русская запись, запятая в дробной части,
-- пробел между разрядами, «−» для отрицательных. Используется только в выводимых строках,
-- расчёты всегда идут по исходным numeric.
-- В to_char шаблонные «,» и «.» не зависят от локали (в отличие от G и D), поэтому
-- результат одинаковый на любом сервере.

CREATE OR REPLACE FUNCTION reporting.fmt_num(p_value numeric, p_digits integer)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE WHEN round(p_value, p_digits) < 0 THEN '−' ELSE '' END
        || translate(
               to_char(abs(round(p_value, p_digits)),
                       'FM999,999,999,999,990' || CASE WHEN p_digits > 0 THEN '.' || repeat('0', p_digits) ELSE '' END),
               ',.', ' ,')
$$;

CREATE OR REPLACE FUNCTION reporting.fmt_signed(p_value numeric, p_digits integer)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
    SELECT CASE WHEN round(p_value, p_digits) > 0 THEN '+' ELSE '' END || reporting.fmt_num(p_value, p_digits)
$$;

-- Миллиарды тенге с одним знаком: 498 153 228 694,57 → «498,2 млрд ₸».
CREATE OR REPLACE FUNCTION reporting.fmt_bn(p_kzt numeric)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT reporting.fmt_num(p_kzt / 1e9, 1) || ' млрд ₸' $$;

CREATE OR REPLACE FUNCTION reporting.fmt_bn_signed(p_kzt numeric)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT reporting.fmt_signed(p_kzt / 1e9, 1) || ' млрд ₸' $$;

-- Доля в процентах: 0.118508 → «11,85%».
CREATE OR REPLACE FUNCTION reporting.fmt_pct(p_share numeric, p_digits integer DEFAULT 2)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT reporting.fmt_num(p_share * 100, p_digits) || '%' $$;

CREATE OR REPLACE FUNCTION reporting.fmt_pct_signed(p_share numeric, p_digits integer DEFAULT 1)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT reporting.fmt_signed(p_share * 100, p_digits) || '%' $$;

-- Изменение доли в процентных пунктах: −1.837 → «−1,84 п.п.».
CREATE OR REPLACE FUNCTION reporting.fmt_pp(p_pp numeric)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$ SELECT reporting.fmt_signed(p_pp, 2) || ' п.п.' $$;
