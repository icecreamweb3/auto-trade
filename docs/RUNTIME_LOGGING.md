# Runtime application logs

Docker console logging remains enabled for every service. Optional file logging adds
UTC daily-rotated files in the persistent `auto-trade-logs` Docker volume.

## Enable file logging

Set these values in `.env`:

```dotenv
LOG_LEVEL=INFO
FILE_LOG_ENABLED=true
FILE_LOG_RETENTION_DAYS=14
```

Then rebuild and recreate the application containers:

```bash
docker compose --profile runtime up -d --build \
  market-writer collector data-repair monitor-api monitor-ui
```

Alternatively, enable file logging for one invocation without editing `.env`:

```bash
FILE_LOG_ENABLED=true docker compose --profile runtime up -d --build \
  market-writer collector data-repair monitor-api
```

Expected files include:

```text
/var/log/auto-trade/collector.log
/var/log/auto-trade/data-repair.log
/var/log/auto-trade/market-writer.log
/var/log/auto-trade/monitor-api.log
```

Files rotate at midnight UTC and are retained for `FILE_LOG_RETENTION_DAYS` days.

## Read and export

Read the collector file inside its container:

```bash
docker compose --profile runtime exec collector \
  tail -n 500 /var/log/auto-trade/collector.log
```

Follow it live:

```bash
docker compose --profile runtime exec collector \
  tail -f /var/log/auto-trade/collector.log
```

Export every application log from the shared volume:

```bash
make logs-export
```

The command creates a UTC timestamped directory under `artifacts/`.

## Disable file logging

Set `FILE_LOG_ENABLED=false` and recreate the application containers. Existing files
remain in the named volume for later export; `docker compose logs` continues to work.

Do not run `docker compose down -v` until required logs are exported because `-v`
removes named volumes, including `auto-trade-logs`.
