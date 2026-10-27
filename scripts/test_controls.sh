#!/usr/bin/env bash
# Проверка проверок. Каждый случай портит данные, модель, выгрузку или README одним известным
# способом и требует, чтобы нужный контроль упал с понятной причиной. Если порча прошла
# незамеченной — контроль не работает, и тест падает.
# Работает в отдельной базе <PGDATABASE>_controls и в .tmp/controls, рабочие файлы не трогает.
set -uo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
ROOT="$PWD"
WORK="$ROOT/.tmp/controls"
TEST_DB="${PGDATABASE}_controls"
failed=0
caught=0

rm -rf "$WORK" && mkdir -p "$WORK"
"${PSQL[@]}" -q -d postgres -c "DROP DATABASE IF EXISTS \"$TEST_DB\"" -c "CREATE DATABASE \"$TEST_DB\"" || exit 1
trap '"${PSQL[@]}" -q -d postgres -c "DROP DATABASE IF EXISTS \"$TEST_DB\"" >/dev/null 2>&1 || true' EXIT

# Сборка и проверки в тестовой базе из каталога со своей копией data/ (пути в \copy относительные).
# VERBOSITY=verbose печатает код SQLSTATE: на него опираемся вместо текста ошибки, который зависит от языка сервера.
build_and_check() {
    local dir="$1" f
    (
        cd "$dir" || exit 1
        for f in "$ROOT"/sql/[0-7]*.sql; do
            PGDATABASE="$TEST_DB" "${PSQL[@]}" -v VERBOSITY=verbose -q -f "$f" || exit 1
        done
        PGDATABASE="$TEST_DB" "${PSQL[@]}" -q -f "$ROOT/sql/90_checks.sql"
    )
}

# expect_fail <случай> <что должно быть в выводе> <команда...>
expect_fail() {
    local name="$1" pattern="$2" out code
    shift 2
    out="$("$@" 2>&1)"; code=$?
    if [ $code -ne 0 ] && grep -qE -- "$pattern" <<<"$out"; then
        echo "  поймано: $name"
        caught=$((caught + 1))
    else
        echo "  НЕ ПОЙМАНО: $name (код $code, ожидалось «$pattern»)"
        tail -5 <<<"$out" | sed 's/^/      /'
        failed=$((failed + 1))
    fi
}

# mutate <случай> <python: правка списков rows (portfolio) и fx> — копия data/ с одной порчей
mutate() {
    local dir="$WORK/$1"
    mkdir -p "$dir/data"
    python3 -I - "$ROOT/data" "$dir/data" "$2" <<'PY'
import csv, sys
src, dst, code = sys.argv[1], sys.argv[2], sys.argv[3]
def read(name):
    with open(f"{src}/{name}", newline="", encoding="utf-8") as f:
        return list(csv.reader(f))
rows, fx = read("portfolio.csv"), read("fx.csv")
exec(code)
for name, data in (("portfolio.csv", rows), ("fx.csv", fx)):
    with open(f"{dst}/{name}", "w", newline="", encoding="utf-8") as f:
        csv.writer(f, lineterminator="\n").writerows(data)
PY
    echo "$dir"
}

echo "== Контроль на исходных данных должен пройти (иначе тест ниже ничего не доказывает)"
clean="$(mutate clean 'pass')"
if build_and_check "$clean" >/dev/null 2>&1; then
    echo "  ok: исходные данные проходят все SQL-проверки"
else
    echo "  FAIL: SQL-проверки падают на исходных данных"; failed=$((failed + 1))
fi
# Колонки reporting из тестовой базы — для проверки семантики (тот же запрос, что в scripts/export.sh).
COLUMNS="$WORK/reporting_columns.json"
PGDATABASE="$TEST_DB" "${PSQL[@]}" -qAt -c "
    SELECT json_agg(json_build_object('view', table_name, 'column', column_name, 'type', data_type)
                    ORDER BY table_name COLLATE \"C\", ordinal_position)
    FROM information_schema.columns WHERE table_schema = 'reporting'" > "$COLUMNS"

echo "== SQL-проверки сырья и витрины (sql/90_checks.sql)"
# колонки: 0 report_date 1 loan_id 6 currency 9 principal 10 dpd 11 restructured 12 written_off
expect_fail "нет курса USD на дату среза" "FAIL.*Курс есть" \
    build_and_check "$(mutate no_fx 'fx[:] = [r for r in fx if r[0] != "2026-10-01"]')"
expect_fail "валюта без курса (EUR)" "FAIL.*Курс есть" \
    build_and_check "$(mutate eur 'next(r for r in rows[1:] if r[6] == "USD")[6] = "EUR"')"
expect_fail "два разных курса на одну дату" "FAIL.*один курс" \
    build_and_check "$(mutate fx_dup 'fx.append([fx[1][0], fx[1][1], "999.99"])')"
expect_fail "разные версии одного кредита на дату" "FAIL.*уникален" \
    build_and_check "$(mutate conflict 'r = list(rows[1]); r[9] = "1.00"; rows.append(r)')"
expect_fail "отрицательный остаток" "FAIL.*остаток > 0" \
    build_and_check "$(mutate negative 'rows[1][9] = "-100.00"')"
expect_fail "нулевой остаток" "FAIL.*остаток > 0" \
    build_and_check "$(mutate zero 'rows[1][9] = "0.00"')"
expect_fail "три знака после точки в остатке" "FAIL.*не более чем 2 знаками" \
    build_and_check "$(mutate scale3 'rows[1][9] = "100.005"')"
expect_fail "отрицательная просрочка" "FAIL.*просрочка — целое" \
    build_and_check "$(mutate dpd_neg 'rows[1][10] = "-5"')"
expect_fail "флаг списания 2" "FAIL.*флаги" \
    build_and_check "$(mutate flag 'rows[1][12] = "2"')"
expect_fail "несуществующая дата" "FAIL.*даты читаются" \
    build_and_check "$(mutate bad_date 'rows[1][0] = "2026-09-31"')"
expect_fail "пустой loan_id" "FAIL.*ключевые поля" \
    build_and_check "$(mutate empty_key 'rows[1][1] = ""')"
expect_fail "просрочка выросла больше, чем прошло дней" "FAIL.*блокирующих аномалий" \
    build_and_check "$(mutate dpd_jump '
loan = next(r[1] for r in rows[1:] if r[0] == "2026-09-01" and r[10] == "0" and r[12] == "0")
for r in rows[1:]:
    if r[1] == loan and r[0] == "2026-10-01": r[10] = "45"
')"
expect_fail "переименована колонка в заголовке CSV (HEADER MATCH, SQLSTATE 22P04)" "22P04" \
    build_and_check "$(mutate header 'rows[0][9] = "principal"')"

echo "== Семантическая модель (checks/validate_semantic.py)"
cp -R semantic "$WORK/sem_col" && sed -i '' 's/column: amount_kzt$/column: amount_tenge/' "$WORK/sem_col/loan_portfolio.yml" 2>/dev/null \
    || sed -i 's/column: amount_kzt$/column: amount_tenge/' "$WORK/sem_col/loan_portfolio.yml"
expect_fail "мера ссылается на несуществующую колонку" "колонки amount_tenge нет" \
    python3 checks/validate_semantic.py --columns-file "$COLUMNS" --semantic-dir "$WORK/sem_col"
cp -R semantic "$WORK/sem_type" && python3 -I - "$WORK/sem_type/loan_portfolio.yml" <<'PY'
import sys; p = sys.argv[1]; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("type: sum", "type: median", 1))
PY
expect_fail "тип меры не из sum/avg/count" "не из \['avg', 'count', 'sum'\]" \
    python3 checks/validate_semantic.py --columns-file "$COLUMNS" --semantic-dir "$WORK/sem_type"
cp -R semantic "$WORK/sem_dimtype" && python3 -I - "$WORK/sem_dimtype/loan_portfolio.yml" <<'PY'
import sys; p = sys.argv[1]; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("column: report_date\n    type: date", "column: report_date\n    type: string", 1))
PY
expect_fail "тип измерения не совпадает с колонкой" "не совпадает с типом колонки" \
    python3 checks/validate_semantic.py --columns-file "$COLUMNS" --semantic-dir "$WORK/sem_dimtype"

echo "== Независимый пересчёт (checks/verify_independent.py)"
mkdir -p "$WORK/exports" && cp dashboard/data/*.json "$WORK/exports/"
python3 -I - "$WORK/exports/v_risk_metrics.json" <<'PY'
import sys; p = sys.argv[1]; s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace('"portfolio_kzt":484674770832.7580', '"portfolio_kzt":484674770832.7590', 1))
PY
expect_fail "портфель в выгрузке SQL на 0,001 ₸ больше" "расхождений [1-9]" \
    python3 checks/verify_independent.py --exports-dir "$WORK/exports"
expect_fail "нет построчной выгрузки v_loans" "v_loans.json НЕ СВЕРЕН" \
    python3 checks/verify_independent.py --loans-file "$WORK/missing.json"

echo "== Числа в README (checks/check_readme_numbers.py)"
python3 -I - README.md "$WORK/README_bad_table.md" <<'PY'
import sys; s = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(s.replace("| NPL | 11,85% | 10,01% |", "| NPL | 11,85% | 10,10% |", 1))
PY
expect_fail "в таблице итогов неверное значение NPL" "README" \
    python3 checks/check_readme_numbers.py --readme "$WORK/README_bad_table.md"
python3 -I - README.md "$WORK/README_bad_text.md" <<'PY'
import sys; s = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(s.replace("15,3 млрд ₸", "15,8 млрд ₸", 1))
PY
expect_fail "в выводах число, которого нет в выводе SQL" "нет в выводе SQL" \
    python3 checks/check_readme_numbers.py --readme "$WORK/README_bad_text.md"

echo
if [ $failed -ne 0 ]; then
    echo "FAIL: не поймано порч — $failed (поймано $caught)"
    exit 1
fi
echo "ok: все $caught порч пойманы своими контролями"
