#!/usr/bin/env bash
# Одноразовый кластер PostgreSQL внутри репозитория (.pgdata, в .gitignore).
# Использование: scripts/pg_local.sh start|stop|status|reset
# Нужен PostgreSQL 16+: initdb и pg_ctl в PATH или каталог с ними в PG_BIN;
# каталог кластера можно сменить через PG_DATA_DIR (по умолчанию ./.pgdata).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

pg() { if [ -n "${PG_BIN:-}" ]; then "$PG_BIN/$1" "${@:2}"; else "$@"; fi; }
DATA_DIR="${PG_DATA_DIR:-$PWD/.pgdata}"
# На macOS postmaster падает при старте с русской локалью терминала
# ("postmaster became multithreaded during startup") — фиксируем локаль.
export LC_ALL=C

start() {
    if [ ! -f "$DATA_DIR/PG_VERSION" ]; then
        pg initdb -D "$DATA_DIR" -U "$PGUSER" --auth=trust --encoding=UTF8 --locale=C >/dev/null
    fi
    if ! pg pg_ctl -D "$DATA_DIR" status >/dev/null 2>&1; then
        pg pg_ctl -D "$DATA_DIR" -l "$DATA_DIR/server.log" -w \
            -o "-p $PGPORT -c listen_addresses=localhost -k /tmp" start >/dev/null
    fi
    if ! psql -X -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" | grep -q 1; then
        createdb "$PGDATABASE"
    fi
    echo "PostgreSQL $(psql -X -tAc 'SHOW server_version') на $PGHOST:$PGPORT, база $PGDATABASE"
}

case "${1:-}" in
    start)  start ;;
    stop)   pg pg_ctl -D "$DATA_DIR" -m fast stop ;;
    status) pg pg_ctl -D "$DATA_DIR" status ;;
    reset)  pg pg_ctl -D "$DATA_DIR" -m fast stop 2>/dev/null || true; rm -rf "$DATA_DIR"; start ;;
    *) echo "usage: $0 start|stop|status|reset" >&2; exit 2 ;;
esac
