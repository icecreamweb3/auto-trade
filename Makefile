.PHONY: db-up db-down db-status db-logs db-migrate db-shell db-verify

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
