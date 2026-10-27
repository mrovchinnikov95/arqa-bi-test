#!/usr/bin/env bash
# Все проверки после сборки. Падает на первой непрошедшей (код возврата ≠ 0).
#   1. SQL-проверки сырья, витрины, определений и инвариантов (sql/90_checks.sql);
#   2. семантические модели: формат, колонки и типы, сверка мер с метриками в базе;
#   3. независимый пересчёт всех выгрузок из сырых CSV вторым кодом (Python, Decimal);
#   4. каждое число в README есть в выводе SQL.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

echo "== 1. SQL-проверки (sql/90_checks.sql)"
"${PSQL[@]}" -q -f sql/90_checks.sql

echo "== 2. Семантические модели (semantic/*.yml)"
python3 checks/validate_semantic.py
"${PSQL[@]}" -q -f .tmp/semantic_check.sql

echo "== 3. Независимый пересчёт из CSV (checks/verify_independent.py)"
python3 checks/verify_independent.py

echo "== 4. Числа в README (checks/check_readme_numbers.py)"
python3 checks/check_readme_numbers.py

echo "Все проверки пройдены."
