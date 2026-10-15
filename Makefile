.PHONY: infra-up infra-down infra-status runtime-up runtime-down runtime-logs logs-export monitor-up monitor-logs repair-once history-rankings-3m history-rankings-status test lint typecheck \
	db-up db-down db-status db-logs db-migrate db-shell db-verify db-storage-verify db-columnstore-poc db-poc db-poc-clean \
	nats-up nats-logs nats-init nats-verify nats-smoke collector-smoke writer-drain

infra-up:
	docker compose up -d database nats

infra-down:
	docker compose down

infra-status:
	docker compose ps

runtime-up:
	docker compose --profile runtime up -d --build market-writer collector data-repair daily-rankings monitor-api monitor-ui

runtime-down:
	docker compose --profile runtime stop market-writer collector data-repair daily-rankings monitor-api monitor-ui

runtime-logs:
	docker compose --profile runtime logs --tail=200 -f market-writer collector data-repair daily-rankings monitor-api monitor-ui

logs-export:
	@export_dir="$(CURDIR)/artifacts/logs-$$(date -u +%Y%m%dT%H%M%SZ)"; \
	mkdir -p "$$export_dir"; \
	docker cp auto-trade-collector:/var/log/auto-trade/. "$$export_dir"; \
	echo "Exported application logs to $$export_dir"

monitor-up:
	docker compose --profile runtime up -d --build monitor-api monitor-ui

monitor-logs:
	docker compose --profile runtime logs --tail=200 -f monitor-api monitor-ui

repair-once:
	docker run --rm --network host --env-file .env \
		--env HTTP_PROXY --env HTTPS_PROXY --env NO_PROXY \
		-v "$(CURDIR):/workspace:ro" -w /tmp -e PYTHONPATH=/workspace/src \
		auto-trade-test:local python -m auto_trade.collectors.data_repair once

history-rankings-3m:
	docker compose --profile tools run --rm --build historical-rankings --days 90

history-rankings-status:
	docker compose exec -T database sh -ec 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" --set=ON_ERROR_STOP=1 -c "SELECT min(utc_trade_date) AS first_day, max(utc_trade_date) AS last_day, count(*) AS daily_metrics, count(*) FILTER (WHERE quality_status = '\''VALID'\'') AS valid_metrics FROM market.utc_daily_metrics;" -c "SELECT min(utc_trade_date) AS first_day, max(utc_trade_date) AS last_day, count(*) AS ranking_days, sum(item_count) AS ranking_entries FROM market.ranking_snapshots WHERE ranking_type = '\''UTC_DAILY_2355'\'';"'

test:
	docker run --rm -v "$(CURDIR):/workspace:ro" -w /workspace \
		-e PYTHONPATH=/workspace/src --entrypoint pytest auto-trade-test:local \
		-q -p no:cacheprovider

lint:
	docker run --rm -v "$(CURDIR):/workspace:ro" -w /workspace \
		--entrypoint ruff auto-trade-test:local check --no-cache .

typecheck:
	docker run --rm -v "$(CURDIR):/workspace:ro" -w /workspace \
		--entrypoint mypy auto-trade-test:local --cache-dir=/tmp/mypy-cache src

db-up:
	docker compose up -d database

db-down:
	docker compose down

db-status:
	docker compose ps

db-logs:
	docker compose logs --tail=200 -f database

db-migrate:
	docker compose --profile tools run --rm db-migrate

db-shell:
	docker compose exec database sh -ec 'exec psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB"'

db-verify:
	docker compose exec -T database sh -ec 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" --set=ON_ERROR_STOP=1 -c "SELECT extversion FROM pg_extension WHERE extname = '\''timescaledb'\'';" -c "SELECT count(*) AS v2_table_count FROM information_schema.tables WHERE table_schema IN ('\''core'\'','\''config'\'','\''market'\'','\''trade'\'','\''analysis'\'','\''audit'\'');" -c "SELECT version, success, applied_at FROM core.schema_migrations ORDER BY applied_at;"'

db-storage-verify:
	docker compose exec -T database sh -ec 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" --set=ON_ERROR_STOP=1 --file=/dev/stdin' < database/storage_optimization_status.sql

db-columnstore-poc:
	docker compose exec -T database sh -ec 'psql -U "$$POSTGRES_USER" -d "$$POSTGRES_DB" --set=ON_ERROR_STOP=1 --file=/dev/stdin' < database/p0_columnstore_benchmark.sql

db-poc:
	./scripts/run_database_poc.sh

db-poc-clean:
	./scripts/cleanup_database_poc.sh

nats-up:
	docker compose up -d nats

nats-logs:
	docker compose logs --tail=200 -f nats

nats-init:
	docker run --rm --network auto-trade-backend -v "$(CURDIR):/workspace:ro" -w /tmp \
		-e PYTHONPATH=/workspace/src \
		-e POSTGRES_PASSWORD=unused -e NATS_URL=nats://nats:4222 \
		auto-trade-test:local python -m auto_trade.infrastructure.nats_streams init

nats-verify:
	docker run --rm --network auto-trade-backend -v "$(CURDIR):/workspace:ro" -w /tmp \
		-e PYTHONPATH=/workspace/src \
		-e POSTGRES_PASSWORD=unused -e NATS_URL=nats://nats:4222 \
		auto-trade-test:local python -m auto_trade.infrastructure.nats_streams verify

nats-smoke:
	docker run --rm --network auto-trade-backend -v "$(CURDIR):/workspace:ro" -w /tmp \
		-e PYTHONPATH=/workspace/src \
		-e POSTGRES_PASSWORD=unused -e NATS_URL=nats://nats:4222 \
		auto-trade-test:local python -m auto_trade.infrastructure.nats_streams smoke

collector-smoke:
	docker run --rm --network host --env HTTP_PROXY --env HTTPS_PROXY --env NO_PROXY \
		-v "$(CURDIR):/workspace:ro" -w /tmp \
		-e PYTHONPATH=/workspace/src \
		-e POSTGRES_PASSWORD=unused -e NATS_URL=nats://127.0.0.1:4222 \
		auto-trade-test:local python -m auto_trade.collectors.cli --symbols BTCUSDT ETHUSDT

writer-drain:
	docker run --rm --network auto-trade-backend --env-file .env \
		-v "$(CURDIR):/workspace:ro" -w /tmp -e PYTHONPATH=/workspace/src \
		-e POSTGRES_HOST=database -e POSTGRES_PORT=5432 -e NATS_URL=nats://nats:4222 \
		auto-trade-test:local python -m auto_trade.writers.market_consumer drain
