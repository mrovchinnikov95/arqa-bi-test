# Общие настройки подключения. Значения по умолчанию — локальный кластер из scripts/pg_local.sh;
# для docker или своего сервера переопределите PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE.
export PGHOST="${PGHOST:-localhost}"
export PGPORT="${PGPORT:-54329}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-arqa_bi}"
# Без ~/.psqlrc, с остановкой на первой ошибке.
PSQL=(psql -X -v ON_ERROR_STOP=1)
# NOTICE от IF NOT EXISTS при повторном запуске — не ошибка, в выводе не нужен.
export PGOPTIONS="${PGOPTIONS:--c client_min_messages=warning}"
