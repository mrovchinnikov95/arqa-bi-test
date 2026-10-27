#!/usr/bin/env bash
# Сборка: сверка CSV с data/SHA256SUMS → схемы → raw (загрузка CSV) → правила → витрина → метрики →
# аналитика → проверки (sql/90_checks.sql) → выгрузка вьюх в JSON для дашборда.
# Если проверка не прошла, сборка останавливается и выгрузка не перезаписывается.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

echo "→ data/SHA256SUMS"
if command -v sha256sum >/dev/null; then
    (cd data && sha256sum --check --quiet SHA256SUMS)
else
    (cd data && shasum -a 256 --check --quiet SHA256SUMS)
fi

for f in sql/00_schemas.sql sql/10_raw_tables.sql sql/20_raw_load.sql \
         sql/30_reporting_rules.sql sql/35_reporting_format.sql sql/40_reporting_mart.sql \
         sql/50_reporting_metrics.sql sql/60_reporting_analysis.sql sql/70_committee_facts.sql; do
    echo "→ $f"
    "${PSQL[@]}" -q -f "$f"
done

echo "→ sql/90_checks.sql"
mkdir -p .tmp
"${PSQL[@]}" -q -f sql/90_checks.sql > .tmp/build_checks.log 2>&1 || { cat .tmp/build_checks.log; exit 1; }
grep -E "^Проверок" .tmp/build_checks.log || true

scripts/export.sh
