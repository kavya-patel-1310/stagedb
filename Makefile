# StageDB — common tasks. Connection settings come from standard libpq env vars
# (PGHOST, PGPORT, PGUSER, PGPASSWORD). Defaults match docker-compose.yml.
export PGHOST     ?= localhost
export PGPORT     ?= 5432
export PGUSER     ?= postgres
export PGPASSWORD ?= postgres
DB ?= stagedb

.PHONY: help up down db seed demo test race bench analytics all clean

help:            ## list targets
	@grep -E '^[a-z]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-10s %s\n", $$1, $$2}'

up:              ## start PostgreSQL 16 in Docker
	docker compose up -d --wait

down:            ## stop and remove the container + volume
	docker compose down -v

db:              ## (re)create the database and apply all migrations
	./scripts/reset_db.sh $(DB)

seed: db         ## build the schema and load ~800k rows of realistic data
	psql -X -q -d $(DB) -f seed/seed.sql

demo:            ## walk through the booking API step by step
	psql -X -q -d $(DB) -f scripts/demo.sql

test:            ## run the SQL test suite (isolated test database)
	./tests/run_tests.sh

race:            ## 50 concurrent sessions fight for the same seats
	./tests/concurrency_test.sh 50

bench:           ## pgbench the checkout path (32 clients, 30s) on the seeded DB
	PGDATABASE=$(DB) ./bench/run_bench.sh 32 30

analytics:       ## run the 10 business-analytics queries
	psql -X -q -d $(DB) -f queries/analytics.sql

all: test race seed analytics  ## everything CI runs

clean:           ## drop all StageDB databases
	for d in $(DB) stagedb_test stagedb_race; do psql -X -q -d postgres -c "DROP DATABASE IF EXISTS $$d WITH (FORCE)"; done
