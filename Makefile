# Короткие команды. Подключение — переменные PG* (см. scripts/env.sh).
.PHONY: all db build check test screenshot stop reset

all: db build check

db:          ## одноразовый кластер PostgreSQL в ./.pgdata на localhost:54329
	scripts/pg_local.sh start

build:       ## схемы, загрузка CSV, вьюхи, выгрузка JSON для дашборда
	scripts/build.sh

check:       ## SQL-проверки, семантика, независимый пересчёт, числа README
	scripts/check.sh

test:        ## идемпотентность и проверка проверок
	scripts/test_idempotency.sh
	scripts/test_controls.sh

screenshot:  ## отрисовка дашборда без ошибок в консоли + docs/dashboard.png
	node scripts/screenshot.mjs

stop:
	scripts/pg_local.sh stop

reset:       ## удалить кластер и поднять заново
	scripts/pg_local.sh reset
