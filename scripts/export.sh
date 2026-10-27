#!/usr/bin/env bash
# Выгрузка вьюх reporting в JSON: dashboard/data — то, что рисует дашборд (в репозитории),
# .tmp/export — построчная витрина и список колонок для проверок (не в репозитории).
# numeric выгружается как есть, без округления: проверки читают его как Decimal.
# Текстовые ключи сортируются с COLLATE "C", чтобы порядок строк не зависел от локали базы.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
mkdir -p dashboard/data .tmp/export

dump() {  # dump <вьюха> <order by> <файл>
    "${PSQL[@]}" -qAt -c "SELECT coalesce(json_agg(t ORDER BY $2), '[]') FROM reporting.$1 t" > "$3"
    echo "  $3"
}

echo "→ выгрузка"
dump v_risk_metrics       "report_date"                             dashboard/data/v_risk_metrics.json
dump v_risk_metrics_long  "report_date, sort_order"                 dashboard/data/v_risk_metrics_long.json
dump v_risk_by_dimension  'dimension COLLATE "C", dimension_value COLLATE "C", report_date' dashboard/data/v_risk_by_dimension.json
dump v_top_groups         "report_date, group_rank"                 dashboard/data/v_top_groups.json
dump v_portfolio_bridge   "report_date, step_order"                 dashboard/data/v_portfolio_bridge.json
dump v_dpd_migration      "report_date, from_order, to_order"       dashboard/data/v_dpd_migration.json
dump v_data_quality       "report_date, check_order"                dashboard/data/v_data_quality.json
dump v_committee_facts    "fact_order"                              dashboard/data/v_committee_facts.json
dump v_loans              'report_date, loan_id COLLATE "C"'        .tmp/export/v_loans.json

# Список колонок reporting для checks/validate_semantic.py (scripts/test_controls.sh снимает его тем же запросом).
"${PSQL[@]}" -qAt -c "
    SELECT json_agg(json_build_object('view', table_name, 'column', column_name, 'type', data_type)
                    ORDER BY table_name COLLATE \"C\", ordinal_position)
    FROM information_schema.columns WHERE table_schema = 'reporting'" > .tmp/export/reporting_columns.json
echo "  .tmp/export/reporting_columns.json"
