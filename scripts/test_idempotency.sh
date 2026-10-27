#!/usr/bin/env bash
# Идемпотентность: на чистой базе собрать проект два раза подряд и сравнить отпечатки
# всех таблиц raw и вьюх reporting (число строк + md5 всех строк) и выгрузок для дашборда.
# Заодно проверяет, что сборка с нуля даёт ровно те выгрузки, что лежат в репозитории.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
TEST_DB="${PGDATABASE}_idempotency"
mkdir -p .tmp

fingerprint() {
    "${PSQL[@]}" -qAt -d "$TEST_DB" <<'SQL'
SELECT string_agg(format('%s.%s|%s', table_schema, table_name, table_type), E'\n' ORDER BY table_schema, table_name)
FROM information_schema.tables WHERE table_schema IN ('raw', 'reporting');
SELECT string_agg(format('%s|%s', p.proname, pg_get_function_identity_arguments(p.oid)), E'\n' ORDER BY p.proname)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'reporting';
DO $$
DECLARE r record; fp text;
BEGIN
    FOR r IN SELECT table_schema, table_name FROM information_schema.tables
             WHERE table_schema IN ('raw', 'reporting') ORDER BY 1, 2 LOOP
        EXECUTE format('SELECT count(*) || '' '' || coalesce(md5(string_agg(t::text, E''\n'' ORDER BY t::text)), ''-'') FROM %I.%I t',
                       r.table_schema, r.table_name) INTO fp;
        -- своя метка fp|: префикс WARNING сервер переводит по lc_messages, на него опираться нельзя
        RAISE WARNING 'fp|%.%|%', r.table_schema, r.table_name, fp;
    END LOOP;
END $$;
SQL
}

data_hash() { (cd dashboard/data && shasum -a 256 *.json); }

before_export="$(data_hash)"
"${PSQL[@]}" -q -d postgres -c "DROP DATABASE IF EXISTS \"$TEST_DB\"" -c "CREATE DATABASE \"$TEST_DB\""
trap '"${PSQL[@]}" -q -d postgres -c "DROP DATABASE IF EXISTS \"$TEST_DB\"" >/dev/null 2>&1 || true' EXIT

PGDATABASE="$TEST_DB" scripts/build.sh >/dev/null
fingerprint > .tmp/idem_run1.txt 2>&1
PGDATABASE="$TEST_DB" scripts/build.sh >/dev/null
fingerprint > .tmp/idem_run2.txt 2>&1
after_export="$(data_hash)"

objects=$(grep -c 'fp|' .tmp/idem_run1.txt || true)
raw_rows=$("${PSQL[@]}" -qAt -d "$TEST_DB" -c "SELECT count(*) FROM raw.portfolio")
file_rows=$(( $(wc -l < data/portfolio.csv) - 1 ))

fail=0
if ! diff -u .tmp/idem_run1.txt .tmp/idem_run2.txt; then echo "FAIL: второй прогон изменил объекты или данные"; fail=1; fi
if [ "$objects" -lt 15 ]; then echo "FAIL: в отпечатке всего $objects объектов — отпечаток не работает"; fail=1; fi
if [ "$raw_rows" != "$file_rows" ]; then echo "FAIL: в raw.portfolio $raw_rows строк, в файле $file_rows — загрузка задвоилась"; fail=1; fi
if [ "$before_export" != "$after_export" ]; then echo "FAIL: сборка с нуля дала другие выгрузки, чем в рабочей копии"; fail=1; fi
# Если есть коммит, сравниваем и с ним: устаревший закоммиченный JSON тоже ошибка.
if git rev-parse --verify -q HEAD >/dev/null 2>&1 && ! git diff --quiet HEAD -- dashboard/data; then
    echo "FAIL: выгрузки отличаются от закоммиченных (git diff HEAD -- dashboard/data)"; fail=1
fi
[ $fail -eq 0 ] || exit 1
echo "ok: два прогона подряд на чистой базе дали одинаковый результат ($objects объектов raw/reporting, raw.portfolio = $raw_rows строк = файлу, выгрузки совпали с рабочей копией и с последним коммитом, если он есть)"
