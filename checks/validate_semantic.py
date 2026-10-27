"""Проверка семантических моделей semantic/*.yml против витрины.

1. Формат: ключи model, source, dimensions, measures; у измерения name/column/type/label,
   у меры name/column/type/format/label; type меры — sum, avg или count.
2. Источник и колонки существуют в reporting, типы измерений совпадают с типами колонок,
   sum/avg — только по числовым колонкам.
3. Генерирует .tmp/semantic_check.sql: запрос, который строит меры модели так, как их построил бы
   BI-инструмент (агрегат по report_date), и сверяет с reporting.v_risk_metrics. Запускает его
   scripts/check.sh через psql: модель должна воспроизводить метрики до тиына.

Колонки витрины берутся из .tmp/export/reporting_columns.json (пишет scripts/export.sh),
поэтому скрипту не нужен драйвер базы. Код возврата 1 — при любой ошибке.
"""
import argparse
import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
COLUMNS_FILE = ROOT / ".tmp/export/reporting_columns.json"
OUT_SQL = ROOT / ".tmp/semantic_check.sql"

MODEL_KEYS = {"model", "source", "dimensions", "measures"}
DIMENSION_KEYS = {"name", "column", "type", "label"}
MEASURE_KEYS = {"name", "column", "type", "format", "label"}
MEASURE_TYPES = {"sum", "avg", "count"}
# тип измерения → допустимые типы колонки PostgreSQL
DIMENSION_TYPES = {
    "string": {"text", "character varying"},
    "date": {"date"},
    "number": {"numeric", "integer", "bigint"},
    "boolean": {"boolean"},
}
NUMERIC_TYPES = {"numeric", "integer", "bigint"}
D3_FORMAT = re.compile(r"^[+\-( ]?,?(\.\d+)?[%dfse]$")

# Какие меры модели loan_portfolio чему равны в reporting.v_risk_metrics.
# Доли проверяются как отношение двух мер — так их считает дашборд.
RECONCILE = {
    "loan_portfolio": [
        ("portfolio_amount", "m.portfolio_kzt"),
        ("par30_amount", "m.par30_kzt"),
        ("par90_amount", "m.par90_kzt"),
        ("npl_amount", "m.npl_kzt"),
        ("restructured_amount", "m.restructured_kzt"),
        ("provisions", "m.provisions_kzt"),
        ("loan_count", "m.loan_count"),
        ("par30_amount / portfolio_amount", "m.par30_share"),
        ("par90_amount / portfolio_amount", "m.par90_share"),
        ("npl_amount / portfolio_amount", "m.npl_share"),
        ("avg_loan_amount", "m.portfolio_kzt / m.loan_count"),
    ],
    "risk_metrics": [
        ("portfolio", "m.portfolio_kzt"),
        ("par30", "m.par30_share"),
        ("par90", "m.par90_share"),
        ("npl", "m.npl_share"),
        ("provisions", "m.provisions_kzt"),
        ("top10_concentration", "m.top10_share"),
        ("loan_count", "m.loan_count"),
    ],
}


def validate(path, columns, errors):
    doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    where = path.name
    if not isinstance(doc, dict) or set(doc) != MODEL_KEYS:
        errors.append(f"{where}: ключи верхнего уровня {sorted(doc) if isinstance(doc, dict) else doc}, нужны {sorted(MODEL_KEYS)}")
        return None
    source = doc["source"]
    if not re.fullmatch(r"reporting\.v_\w+", source or ""):
        errors.append(f"{where}: source {source!r} не вида reporting.v_*")
        return None
    view = source.split(".", 1)[1]
    if view not in columns:
        errors.append(f"{where}: вьюхи {source} нет в базе")
        return None
    cols = columns[view]
    names = set()

    for kind, items, keys in (("dimension", doc["dimensions"], DIMENSION_KEYS), ("measure", doc["measures"], MEASURE_KEYS)):
        if not isinstance(items, list) or not items:
            errors.append(f"{where}: {kind}s пустой или не список")
            continue
        for item in items:
            label = f"{where}: {kind} {item.get('name') if isinstance(item, dict) else item!r}"
            if not isinstance(item, dict) or set(item) != keys:
                errors.append(f"{label}: ключи {sorted(item) if isinstance(item, dict) else item}, нужны {sorted(keys)}")
                continue
            if not all(isinstance(item[k], str) and item[k].strip() for k in keys):
                errors.append(f"{label}: пустое или нестроковое поле")
                continue
            if item["name"] in names:
                errors.append(f"{label}: имя повторяется")
            names.add(item["name"])
            col_type = cols.get(item["column"])
            if col_type is None:
                errors.append(f"{label}: колонки {item['column']} нет в {source}")
                continue
            if kind == "dimension":
                if item["type"] not in DIMENSION_TYPES:
                    errors.append(f"{label}: тип {item['type']!r} не из {sorted(DIMENSION_TYPES)}")
                elif col_type not in DIMENSION_TYPES[item["type"]]:
                    errors.append(f"{label}: тип {item['type']} не совпадает с типом колонки {col_type}")
            else:
                if item["type"] not in MEASURE_TYPES:
                    errors.append(f"{label}: тип {item['type']!r} не из {sorted(MEASURE_TYPES)}")
                elif item["type"] in ("sum", "avg") and col_type not in NUMERIC_TYPES:
                    errors.append(f"{label}: {item['type']} по нечисловой колонке ({col_type})")
                if not D3_FORMAT.match(item["format"]):
                    errors.append(f"{label}: format {item['format']!r} не похож на d3-format")
    if not any(d.get("column") == "report_date" for d in doc["dimensions"] if isinstance(d, dict)):
        errors.append(f"{where}: нет измерения report_date — портфель нельзя складывать между датами")
    return doc


def semantic_sql(doc):
    """SQL, который строит меры модели по report_date и сверяет с v_risk_metrics."""
    model = doc["model"]
    checks = RECONCILE.get(model)
    if not checks:
        return None, []
    measures = ",\n        ".join(
        f"{m['type']}({m['column']}) AS {m['name']}" for m in doc["measures"]
    )
    known = {m["name"] for m in doc["measures"]}
    used = {n for expr, _ in checks for n in re.findall(r"[a-z_0-9]+", expr) if n in known}
    unchecked = sorted(known - used)
    conds = "\n        OR ".join(f"s.{expr.replace(' / ', ' / s.')} IS DISTINCT FROM {target}" for expr, target in checks)
    sql = f"""
-- {model}: меры модели, собранные по report_date, против reporting.v_risk_metrics
DO $$
DECLARE bad int; n_sem int; n_ref int;
BEGIN
    CREATE TEMP TABLE sem_{model} ON COMMIT DROP AS
    SELECT report_date,
        {measures}
    FROM {doc['source']}
    GROUP BY report_date;

    SELECT count(*) INTO n_sem FROM sem_{model};
    SELECT count(*) INTO n_ref FROM reporting.v_risk_metrics;
    SELECT count(*) INTO bad
    FROM sem_{model} s JOIN reporting.v_risk_metrics m USING (report_date)
    WHERE {conds};

    IF bad > 0 OR n_sem <> n_ref THEN
        RAISE EXCEPTION 'семантика {model}: расхождений % (дат в модели %, в метриках %)', bad, n_sem, n_ref;
    END IF;
    RAISE NOTICE 'ok  семантика {model}: % сверок × % дат совпали с v_risk_metrics', {len(checks)}, n_sem;
END $$;
"""
    return sql, unchecked


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--semantic-dir", default=str(ROOT / "semantic"), help="каталог с моделями *.yml")
    ap.add_argument("--columns-file", type=Path, default=COLUMNS_FILE, help="колонки reporting (JSON из scripts/export.sh)")
    args = ap.parse_args()
    if not args.columns_file.exists():
        print(f"нет {args.columns_file} — сначала scripts/build.sh", file=sys.stderr)
        return 1
    columns = {}
    for row in json.loads(args.columns_file.read_text(encoding="utf-8")):
        columns.setdefault(row["view"], {})[row["column"]] = row["type"]

    errors, parts = [], ["\\set ON_ERROR_STOP on", "SET client_min_messages = notice;"]
    files = sorted(Path(args.semantic_dir).glob("*.yml"))
    if not files:
        errors.append(f"в {args.semantic_dir} нет ни одной модели")
    for path in files:
        doc = validate(path, columns, errors)
        if doc is None:
            continue
        sql, unchecked = semantic_sql(doc)
        dims, meas = len(doc["dimensions"]), len(doc["measures"])
        print(f"ok  {path.name}: model {doc['model']}, source {doc['source']}, измерений {dims}, мер {meas}")
        if sql:
            parts.append(sql)
            if unchecked:
                print(f"    без эталона для сверки (проверены только колонка и тип): {', '.join(unchecked)}")
        else:
            print(f"    сверка с метриками для модели {doc['model']} не задана")

    if errors:
        print("ОШИБКИ:\n" + "\n".join("  " + e for e in errors), file=sys.stderr)
        return 1
    OUT_SQL.write_text("\n".join(parts), encoding="utf-8")
    print(f"→ {OUT_SQL.relative_to(ROOT)} (сверка мер с метриками в базе)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
