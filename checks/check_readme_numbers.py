"""Числа в README — только из вывода SQL.

1. Таблицы итогов между маркерами <!-- metrics-table:* --> и <!-- exact-table:* -->
   должны совпадать с тем, что строится из dashboard/data/v_risk_metrics_long.json.
   С флагом --write скрипт сам перерисовывает эти таблицы.
2. В проверяемых фрагментах между <!-- checked:start --> и <!-- checked:end -->
   каждое число (суммы, проценты, п.п., количества) должно встречаться в подписях
   выгрузок SQL: v_risk_metrics_long, v_committee_facts, v_data_quality, v_portfolio_bridge
   (число без знака допускается, если со знаком оно есть в SQL: «снизился на 1,84 п.п.»).
   Без вывода SQL допускаются только константы из определений (1, 10, 30, 31, 90, 91 и ставки
   1%, 10%, 50%) и номера пунктов.

Что проверка не ловит: число из SQL, поставленное не к той метрике в тексте выводов.
Это закрывает вычитка и то, что подписи фактов в v_committee_facts именованы.
"""
import argparse
import json
import re
import sys
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MINUS = "−"

ALLOWED_CONSTANTS = {"1", "2", "3", "10", "30", "31", "90", "91", "1%", "10%", "50%"}

# Сначала вырезаем то, что числом-метрикой не является: даты, идентификаторы, названия метрик,
# диапазоны дней, ссылки и код.
NOT_NUMBERS = [
    r"`[^`]*`",                       # код и идентификаторы
    r"\]\([^)]*\)",                   # адреса ссылок
    r"\b\d{2}\.\d{2}(?:\.\d{4})?\b",  # даты 01.10 и 01.10.2026
    r"\b[A-Z]+\d+\b",                 # G0004, L001018, PAR30
    r"\b\d+[–-]\d+\b",                # 31–90, 0–30
    r"\b\d+\+",                       # 90+
    r"[Тт]оп-10",
]
GROUPED = r"[+−]?\d{1,3}(?: \d{3})*(?:,\d+)?"
TOKEN = re.compile(
    rf"{GROUPED} млрд ₸|{GROUPED} ₸|[+−]?\d+(?:,\d+)?%|[+−]?\d+(?:,\d+)? п\.п\.|{GROUPED}"
)


def fmt_num(x, d):
    r = Decimal(x).quantize(Decimal(1).scaleb(-d), rounding=ROUND_HALF_UP)
    whole, _, frac = f"{abs(r):f}".partition(".")
    out = f"{int(whole):,}".replace(",", " ") + ("," + frac if d else "")
    return (MINUS if r < 0 else "") + out


def tokens(text):
    for pattern in NOT_NUMBERS:
        text = re.sub(pattern, " ", text)
    return TOKEN.findall(text)


def load(exports, name):
    return json.loads((exports / name).read_text(encoding="utf-8"), parse_float=Decimal)


def render_tables(long_rows):
    dates = sorted({r["report_date"] for r in long_rows})
    label = lambda iso: f"{iso[8:10]}.{iso[5:7]}.{iso[0:4]}"
    by = {(r["report_date"], r["metric_code"]): r for r in long_rows}
    metrics = sorted({(r["sort_order"], r["metric_code"], r["metric_label"], r["unit"]) for r in long_rows})
    last, prev = dates[-1], dates[-2]

    head = f"| Метрика | {' | '.join(label(d) for d in dates)} | Изменение к {label(prev)[:5]} |"
    rows = [head, "|---" + "|---:" * (len(dates) + 1) + "|"]
    for _, code, name, unit in metrics:
        name = "Кредитов в портфеле" if code == "loans" else name
        cells = [by[(d, code)]["value_display"] for d in dates]
        rows.append(f"| {name} | {' | '.join(cells)} | {by[(last, code)]['change_display']} |")
    metrics_table = "\n".join(rows)

    rows = [f"| Сумма, ₸ | {' | '.join(label(d) for d in dates)} |", "|---" + "|---:" * len(dates) + "|"]
    for _, code, name, unit in metrics:
        if unit == "kzt":
            rows.append(f"| {name} | {' | '.join(by[(d, code)]['value_exact_display'] for d in dates)} |")
    exact_table = "\n".join(rows)
    return {"metrics-table": metrics_table, "exact-table": exact_table}


def block(text, name):
    m = re.search(rf"<!-- {name}:start -->\n(.*?)\n<!-- {name}:end -->", text, re.S)
    return m


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--readme", type=Path, default=ROOT / "README.md")
    ap.add_argument("--exports-dir", type=Path, default=ROOT / "dashboard" / "data")
    ap.add_argument("--write", action="store_true", help="перерисовать таблицы итогов в README")
    args = ap.parse_args()

    text = args.readme.read_text(encoding="utf-8")
    long_rows = load(args.exports_dir, "v_risk_metrics_long.json")
    facts = load(args.exports_dir, "v_committee_facts.json")
    dq = load(args.exports_dir, "v_data_quality.json")
    tables = render_tables(long_rows)
    errors = []

    if args.write:
        for name, table in tables.items():
            if not block(text, name):
                print(f"в README нет маркеров {name}", file=sys.stderr)
                return 1
            text = re.sub(rf"(<!-- {name}:start -->\n).*?(\n<!-- {name}:end -->)",
                          lambda m: m.group(1) + table + m.group(2), text, flags=re.S)
        args.readme.write_text(text, encoding="utf-8")
        print(f"таблицы итогов в {args.readme.name} перерисованы из выгрузки SQL")

    for name, table in tables.items():
        m = block(text, name)
        if not m:
            errors.append(f"README: нет таблицы {name}")
        elif m.group(1).strip() != table:
            errors.append(f"README: таблица {name} не совпадает с выводом SQL — запустите с --write")

    allowed = set(ALLOWED_CONSTANTS)
    sources = [r[k] for r in long_rows for k in ("value_display", "change_display", "value_exact_display") if r[k]]
    sources += [f["display"] for f in facts if f["display"]]
    sources += [fmt_num(r["row_count"], 0) for r in dq if r["row_count"] is not None]
    sources += [fmt_num(r["amount_kzt"] / Decimal(10) ** 9, 1) + " млрд ₸" for r in dq if r["amount_kzt"] is not None]
    bridge = load(args.exports_dir, "v_portfolio_bridge.json")
    sources += [("+" if r["amount_kzt"] > 0 else "") + fmt_num(r["amount_kzt"] / Decimal(10) ** 9, 1) + " млрд ₸"
                for r in bridge]
    for s in sources:
        allowed.add(s)
        allowed.update(tokens(s))
    # В тексте «снизился на 1,84 п.п.» знак передаёт глагол: модуль числа тоже из SQL.
    allowed.update({t[1:] for t in list(allowed) if t[:1] in ("+", MINUS)})

    regions = re.findall(r"<!-- checked:start -->\n(.*?)\n<!-- checked:end -->", text, re.S)
    if not regions:
        errors.append("README: нет ни одного фрагмента <!-- checked:start -->")
    checked = 0
    for region in regions:
        for tok in tokens(region):
            checked += 1
            if tok not in allowed:
                errors.append(f"README: «{tok}» нет в выводе SQL")

    if errors:
        print("ОШИБКИ:\n" + "\n".join("  " + e for e in errors), file=sys.stderr)
        return 1
    print(f"ok: таблицы итогов совпадают с выводом SQL; в {len(regions)} фрагментах проверено чисел: {checked}, "
          f"все есть в выводе SQL")
    return 0


if __name__ == "__main__":
    sys.exit(main())
