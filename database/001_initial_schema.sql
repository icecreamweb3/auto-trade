-- Trading Bot 2.0 - PostgreSQL 16 + TimescaleDB initial schema
-- Baseline: TRADING_BOT_2_0_REQUIREMENTS.md Draft 0.276
-- All timestamps are UTC instants. Applications must execute: SET TIME ZONE 'UTC'.
-- This migration is intentionally non-destructive and does not import 1.0 data.

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('trading_bot_v2_schema_migration', 0));

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS timescaledb;

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS config;
CREATE SCHEMA IF NOT EXISTS market;
CREATE SCHEMA IF NOT EXISTS trade;
CREATE SCHEMA IF NOT EXISTS analysis;
CREATE SCHEMA IF NOT EXISTS audit;

CREATE OR REPLACE FUNCTION core.set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := clock_timestamp();
    RETURN NEW;
END;
$$;

CREATE TABLE IF NOT EXISTS core.schema_migrations (
    version             varchar(64) PRIMARY KEY,
    checksum_sha256     char(64) NOT NULL,
    description         text NOT NULL,
    applied_by          text NOT NULL DEFAULT current_user,
    applied_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    duration_ms         bigint,
    success             boolean NOT NULL DEFAULT true,
    details             jsonb NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS core.service_instances (
    instance_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    environment         varchar(16) NOT NULL CHECK (environment IN ('DEV','TEST','SHADOW','PROD')),
    service_name        varchar(80) NOT NULL,
    node_id             varchar(80) NOT NULL,
    shard_id            varchar(80) NOT NULL DEFAULT '0',
    generation          bigint NOT NULL DEFAULT 1 CHECK (generation > 0),
    build_version       varchar(80) NOT NULL,
    started_at          timestamptz NOT NULL,
    heartbeat_at        timestamptz NOT NULL,
    stopped_at          timestamptz,
    metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (environment, service_name, node_id, generation)
);

CREATE TABLE IF NOT EXISTS core.instruments (
    instrument_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    exchange            varchar(32) NOT NULL DEFAULT 'BINANCE',
    market              varchar(32) NOT NULL DEFAULT 'USD_M_FUTURES',
    symbol              varchar(32) NOT NULL,
    base_asset          varchar(24) NOT NULL,
    quote_asset         varchar(24) NOT NULL CHECK (quote_asset = 'USDT'),
    contract_type       varchar(24) NOT NULL CHECK (contract_type = 'PERPETUAL'),
    trading_status      varchar(24) NOT NULL,
    onboard_at          timestamptz,
    delisted_at         timestamptz,
    first_seen_at       timestamptz NOT NULL,
    last_seen_at        timestamptz NOT NULL,
    status_effective_at timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (exchange, market, symbol),
    CHECK (delisted_at IS NULL OR onboard_at IS NULL OR delisted_at >= onboard_at)
);

DROP TRIGGER IF EXISTS trg_instruments_updated_at ON core.instruments;
CREATE TRIGGER trg_instruments_updated_at
BEFORE UPDATE ON core.instruments
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE IF NOT EXISTS core.instrument_rule_versions (
    rule_version_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    effective_from      timestamptz NOT NULL,
    effective_to        timestamptz,
    price_precision     smallint NOT NULL CHECK (price_precision >= 0),
    quantity_precision  smallint NOT NULL CHECK (quantity_precision >= 0),
    tick_size           numeric(38,18) NOT NULL CHECK (tick_size > 0),
    step_size           numeric(38,18) NOT NULL CHECK (step_size > 0),
    min_quantity        numeric(38,18),
    max_quantity        numeric(38,18),
    min_notional        numeric(38,18),
    max_notional        numeric(38,18),
    market_step_size    numeric(38,18),
    market_min_quantity numeric(38,18),
    market_max_quantity numeric(38,18),
    max_open_orders     integer,
    max_algo_orders     integer,
    percent_price_rules jsonb NOT NULL DEFAULT '{}'::jsonb,
    leverage_brackets   jsonb NOT NULL DEFAULT '[]'::jsonb,
    complete_rule_payload jsonb NOT NULL,
    source_event_id     uuid,
    payload_hash        char(64) NOT NULL,
    exchange_data_time  timestamptz,
    collected_at        timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (instrument_id, effective_from),
    CHECK (effective_to IS NULL OR effective_to > effective_from),
    CHECK (min_quantity IS NULL OR min_quantity >= 0),
    CHECK (max_quantity IS NULL OR min_quantity IS NULL OR max_quantity >= min_quantity)
);

CREATE INDEX IF NOT EXISTS ix_instrument_rules_current
ON core.instrument_rule_versions (instrument_id, effective_from DESC);

CREATE TABLE IF NOT EXISTS core.instrument_status_history (
    instrument_status_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    exchange_status     varchar(32) NOT NULL,
    system_status       varchar(32) NOT NULL,
    discovered_at       timestamptz NOT NULL,
    effective_at        timestamptz NOT NULL,
    planned_stop_at     timestamptz,
    recovered_at        timestamptz,
    disposition         jsonb NOT NULL DEFAULT '{}'::jsonb,
    source_event_id     uuid,
    payload_hash        char(64) NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (instrument_id, effective_at, payload_hash)
);

CREATE INDEX IF NOT EXISTS ix_instrument_status_time
ON core.instrument_status_history (instrument_id, effective_at DESC);

CREATE TABLE IF NOT EXISTS core.exchange_accounts (
    account_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    exchange            varchar(32) NOT NULL DEFAULT 'BINANCE',
    account_alias       varchar(80) NOT NULL,
    parent_account_id   uuid REFERENCES core.exchange_accounts(account_id),
    is_main_account     boolean NOT NULL DEFAULT false,
    can_live_trade      boolean NOT NULL DEFAULT false,
    credential_ref      text,
    position_mode       varchar(16) NOT NULL DEFAULT 'ONE_WAY' CHECK (position_mode IN ('ONE_WAY','HEDGE')),
    margin_asset_mode   varchar(24) NOT NULL DEFAULT 'SINGLE_ASSET' CHECK (margin_asset_mode IN ('SINGLE_ASSET','MULTI_ASSET')),
    status              varchar(24) NOT NULL DEFAULT 'ACTIVE' CHECK (status IN ('ACTIVE','PAUSED','DISABLED','CLOSED')),
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (exchange, account_alias),
    CHECK (NOT is_main_account OR NOT can_live_trade),
    CHECK (NOT can_live_trade OR credential_ref IS NOT NULL)
);

DROP TRIGGER IF EXISTS trg_exchange_accounts_updated_at ON core.exchange_accounts;
CREATE TRIGGER trg_exchange_accounts_updated_at
BEFORE UPDATE ON core.exchange_accounts
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

-- Raw events are append-only. Raw payload is hot data; archive before retention removal.
CREATE TABLE IF NOT EXISTS market.raw_events (
    event_id            uuid NOT NULL,
    event_time          timestamptz NOT NULL,
    exchange            varchar(32) NOT NULL,
    market              varchar(32) NOT NULL,
    symbol              varchar(32),
    event_type          varchar(48) NOT NULL,
    schema_version      smallint NOT NULL CHECK (schema_version > 0),
    source              varchar(16) NOT NULL CHECK (source IN ('WEBSOCKET','REST','ARCHIVE','BACKFILL','DERIVED')),
    exchange_event_time timestamptz,
    collected_at        timestamptz NOT NULL,
    published_at        timestamptz,
    node_id             varchar(80) NOT NULL,
    shard_id            varchar(80) NOT NULL DEFAULT '0',
    payload_hash        char(64) NOT NULL,
    payload             jsonb NOT NULL,
    quality_status      varchar(24) NOT NULL DEFAULT 'VALID' CHECK (quality_status IN ('VALID','DEGRADED','INVALID','QUARANTINED')),
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (event_id, event_time)
);

CREATE INDEX IF NOT EXISTS ix_raw_events_business_time
ON market.raw_events (event_type, symbol, event_time DESC);

CREATE INDEX IF NOT EXISTS ix_raw_events_hash
ON market.raw_events (payload_hash, event_time DESC);

SELECT create_hypertable('market.raw_events', by_range('event_time'), if_not_exists => TRUE);

-- Canonical K-lines. 1m and 5m are permanent source intervals; higher periods are derived.
CREATE TABLE IF NOT EXISTS market.klines (
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    price_type          varchar(24) NOT NULL CHECK (price_type IN ('TRADE','MARK','INDEX','PREMIUM_INDEX')),
    interval_seconds    integer NOT NULL CHECK (
        interval_seconds IN (60,300)
        OR (interval_seconds BETWEEN 600 AND 604800 AND interval_seconds % 300 = 0)
    ),
    open_time           timestamptz NOT NULL,
    revision_no         integer NOT NULL DEFAULT 1 CHECK (revision_no > 0),
    is_current          boolean NOT NULL DEFAULT true,
    supersedes_revision integer,
    close_time          timestamptz NOT NULL,
    open_price          numeric(38,18) NOT NULL CHECK (open_price > 0),
    high_price          numeric(38,18) NOT NULL CHECK (high_price > 0),
    low_price           numeric(38,18) NOT NULL CHECK (low_price > 0),
    close_price         numeric(38,18) NOT NULL CHECK (close_price > 0),
    base_volume         numeric(38,18) CHECK (base_volume >= 0),
    quote_volume        numeric(38,18) CHECK (quote_volume >= 0),
    trade_count         bigint CHECK (trade_count >= 0),
    taker_buy_base      numeric(38,18),
    taker_buy_quote     numeric(38,18),
    is_closed           boolean NOT NULL,
    source              varchar(16) NOT NULL CHECK (source IN ('WEBSOCKET','REST','ARCHIVE','BACKFILL','DERIVED')),
    derivation_version  varchar(64),
    data_rule_version   varchar(64) NOT NULL,
    update_count        integer NOT NULL DEFAULT 0 CHECK (update_count >= 0),
    source_event_ids    uuid[] NOT NULL DEFAULT '{}',
    payload_hash        char(64) NOT NULL,
    quality_status      varchar(24) NOT NULL CHECK (quality_status IN ('VALID','PARTIAL','DEGRADED','INVALID','QUARANTINED')),
    collected_at        timestamptz NOT NULL,
    effective_at        timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (instrument_id, price_type, interval_seconds, open_time, revision_no),
    CHECK (close_time > open_time),
    CHECK (high_price >= GREATEST(open_price, close_price, low_price)),
    CHECK (low_price <= LEAST(open_price, close_price, high_price)),
    CHECK (supersedes_revision IS NULL OR supersedes_revision < revision_no),
    CHECK (price_type <> 'TRADE' OR (base_volume IS NOT NULL AND quote_volume IS NOT NULL)),
    CHECK ((source = 'DERIVED') = (derivation_version IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS ix_klines_interval_time
ON market.klines (price_type, interval_seconds, open_time DESC, instrument_id);

CREATE UNIQUE INDEX IF NOT EXISTS ux_klines_current_business_key
ON market.klines (instrument_id, price_type, interval_seconds, open_time)
WHERE is_current;

SELECT create_hypertable('market.klines', by_range('open_time'), if_not_exists => TRUE);

CREATE OR REPLACE FUNCTION market.guard_confirmed_kline_revision()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.is_closed AND OLD.quality_status = 'VALID' THEN
        IF NOT (
            OLD.is_current
            AND NOT NEW.is_current
            AND (to_jsonb(NEW) - 'is_current') = (to_jsonb(OLD) - 'is_current')
        ) THEN
            RAISE EXCEPTION 'confirmed kline revisions are append-only: %, %, %, %, rev %',
                OLD.instrument_id, OLD.price_type, OLD.interval_seconds, OLD.open_time, OLD.revision_no;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_confirmed_kline_revision ON market.klines;
CREATE TRIGGER trg_guard_confirmed_kline_revision
BEFORE UPDATE ON market.klines
FOR EACH ROW EXECUTE FUNCTION market.guard_confirmed_kline_revision();

CREATE TABLE IF NOT EXISTS market.ticker_minutes (
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    minute_time         timestamptz NOT NULL,
    last_price          numeric(38,18) NOT NULL CHECK (last_price > 0),
    mark_price          numeric(38,18) CHECK (mark_price > 0),
    index_price         numeric(38,18) CHECK (index_price > 0),
    price_change_24h    numeric(20,10),
    rolling_window_start timestamptz,
    rolling_window_end  timestamptz,
    rolling_open_price  numeric(38,18),
    quote_volume_24h    numeric(38,18),
    high_price_24h      numeric(38,18),
    low_price_24h       numeric(38,18),
    source_event_ids    uuid[] NOT NULL DEFAULT '{}',
    source              varchar(16) NOT NULL CHECK (source IN ('WEBSOCKET','REST','ARCHIVE','BACKFILL','DERIVED')),
    derivation_version  varchar(64),
    payload_hash        char(64) NOT NULL,
    quality_status      varchar(24) NOT NULL CHECK (quality_status IN ('VALID','PARTIAL','DEGRADED','INVALID','QUARANTINED')),
    exchange_event_time timestamptz,
    collected_at        timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (instrument_id, minute_time),
    CHECK ((source = 'DERIVED') = (derivation_version IS NOT NULL)),
    CHECK (rolling_window_end IS NULL OR rolling_window_start IS NULL OR rolling_window_end > rolling_window_start)
);

CREATE INDEX IF NOT EXISTS ix_ticker_minutes_time
ON market.ticker_minutes (minute_time DESC, instrument_id);

SELECT create_hypertable('market.ticker_minutes', by_range('minute_time'), if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS market.open_interest_observations (
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    observed_at         timestamptz NOT NULL,
    open_interest_qty   numeric(38,18) NOT NULL CHECK (open_interest_qty >= 0),
    open_interest_value numeric(38,18),
    source              varchar(16) NOT NULL CHECK (source IN ('REST','ARCHIVE','BACKFILL')),
    source_event_id     uuid,
    payload_hash        char(64) NOT NULL,
    quality_status      varchar(24) NOT NULL CHECK (quality_status IN ('VALID','PARTIAL','DEGRADED','INVALID','QUARANTINED')),
    collected_at        timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (instrument_id, observed_at)
);

CREATE INDEX IF NOT EXISTS ix_oi_observed_at
ON market.open_interest_observations (observed_at DESC, instrument_id);

SELECT create_hypertable('market.open_interest_observations', by_range('observed_at'), if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS market.funding_observations (
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    observed_at         timestamptz NOT NULL,
    current_rate        numeric(20,12) NOT NULL,
    last_settled_rate   numeric(20,12),
    last_settled_at     timestamptz,
    next_settlement_at  timestamptz,
    mark_price          numeric(38,18),
    source              varchar(16) NOT NULL CHECK (source IN ('WEBSOCKET','REST','ARCHIVE','BACKFILL')),
    source_event_id     uuid,
    payload_hash        char(64) NOT NULL,
    quality_status      varchar(24) NOT NULL CHECK (quality_status IN ('VALID','PARTIAL','DEGRADED','INVALID','QUARANTINED')),
    collected_at        timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (instrument_id, observed_at),
    CHECK (next_settlement_at IS NULL OR next_settlement_at >= observed_at)
);

CREATE INDEX IF NOT EXISTS ix_funding_observed_at
ON market.funding_observations (observed_at DESC, instrument_id);

SELECT create_hypertable('market.funding_observations', by_range('observed_at'), if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS market.derivative_metrics_5m (
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    open_time           timestamptz NOT NULL,
    open_interest_qty   numeric(38,18),
    open_interest_value numeric(38,18),
    oi_reference_values jsonb NOT NULL DEFAULT '{}'::jsonb,
    oi_change_rates     jsonb NOT NULL DEFAULT '{}'::jsonb,
    global_long_short_ratio numeric(20,12),
    top_account_long_short_ratio numeric(20,12),
    top_position_long_short_ratio numeric(20,12),
    taker_buy_sell_ratio numeric(20,12),
    current_funding_rate numeric(20,12),
    last_settled_funding_rate numeric(20,12),
    last_settled_at     timestamptz,
    next_settlement_at  timestamptz,
    mark_price          numeric(38,18),
    exchange_event_time timestamptz,
    source              varchar(16) NOT NULL CHECK (source IN ('WEBSOCKET','REST','ARCHIVE','BACKFILL','DERIVED')),
    source_event_ids    uuid[] NOT NULL DEFAULT '{}',
    data_rule_version   varchar(64) NOT NULL,
    payload_hash        char(64) NOT NULL,
    quality_status      varchar(24) NOT NULL CHECK (quality_status IN ('VALID','PARTIAL','DEGRADED','INVALID','QUARANTINED')),
    collected_at        timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (instrument_id, open_time)
);

CREATE INDEX IF NOT EXISTS ix_derivative_metrics_5m_time
ON market.derivative_metrics_5m (open_time DESC, instrument_id);

SELECT create_hypertable('market.derivative_metrics_5m', by_range('open_time'), if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS market.interval_snapshots (
    interval_snapshot_id uuid NOT NULL DEFAULT gen_random_uuid(),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    interval_seconds    integer NOT NULL CHECK (interval_seconds BETWEEN 300 AND 604800 AND interval_seconds % 300 = 0),
    open_time           timestamptz NOT NULL,
    close_time          timestamptz NOT NULL,
    offset_seconds      integer NOT NULL DEFAULT 0 CHECK (offset_seconds >= 0),
    revision_no         integer NOT NULL DEFAULT 1 CHECK (revision_no > 0),
    is_current          boolean NOT NULL DEFAULT true,
    status              varchar(24) NOT NULL CHECK (status IN ('BUILDING','CONFIRMED','INCOMPLETE','STALE','QUARANTINED')),
    trade_ohlcv         jsonb NOT NULL,
    mark_ohlc           jsonb,
    index_ohlc          jsonb,
    premium_index_ohlc  jsonb,
    oi_metrics          jsonb,
    funding_metrics     jsonb,
    rolling_24h_metrics jsonb,
    indicator_values    jsonb NOT NULL DEFAULT '{}'::jsonb,
    input_references    jsonb NOT NULL,
    aggregation_version varchar(64) NOT NULL,
    indicator_version   varchar(64),
    snapshot_hash       char(64) NOT NULL,
    quality_status      varchar(24) NOT NULL,
    generated_at        timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (interval_snapshot_id, open_time),
    UNIQUE (instrument_id, interval_seconds, open_time, offset_seconds, revision_no),
    CHECK (close_time > open_time)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_interval_snapshots_current
ON market.interval_snapshots (instrument_id, interval_seconds, open_time, offset_seconds)
WHERE is_current;

CREATE INDEX IF NOT EXISTS ix_interval_snapshots_lookup
ON market.interval_snapshots (interval_seconds, open_time DESC, instrument_id)
WHERE is_current AND status = 'CONFIRMED';

SELECT create_hypertable('market.interval_snapshots', by_range('open_time'), if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS market.supply_observations (
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    observed_at         timestamptz NOT NULL,
    circulating_supply  numeric(38,18),
    total_supply        numeric(38,18),
    circulating_market_cap_usdt numeric(38,18),
    price_used          numeric(38,18),
    provider            varchar(80) NOT NULL,
    source_reference    text,
    payload_hash        char(64) NOT NULL,
    quality_status      varchar(24) NOT NULL,
    collected_at        timestamptz NOT NULL,
    PRIMARY KEY (instrument_id, observed_at, provider)
);

SELECT create_hypertable('market.supply_observations', by_range('observed_at'), if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS market.ranking_snapshots (
    ranking_snapshot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    ranking_type        varchar(32) NOT NULL CHECK (ranking_type IN ('ROLLING_24H_5M','UTC_DAILY_2355')),
    snapshot_at         timestamptz NOT NULL,
    utc_trade_date      date,
    scheduled_at        timestamptz NOT NULL,
    generated_at        timestamptz NOT NULL,
    generation_mode     varchar(16) NOT NULL CHECK (generation_mode IN ('REALTIME','BACKFILLED','DERIVED')),
    source_kline_time   timestamptz,
    window_start        timestamptz NOT NULL,
    window_end          timestamptz NOT NULL,
    item_count          smallint NOT NULL CHECK (item_count BETWEEN 0 AND 50),
    source_event_ids    uuid[] NOT NULL DEFAULT '{}',
    snapshot_hash       char(64) NOT NULL,
    quality_status      varchar(24) NOT NULL CHECK (quality_status IN ('VALID','PARTIAL','DEGRADED','INVALID')),
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (ranking_type, snapshot_at),
    CHECK (window_end > window_start),
    CHECK (ranking_type <> 'UTC_DAILY_2355' OR utc_trade_date IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS market.ranking_entries (
    ranking_snapshot_id uuid NOT NULL REFERENCES market.ranking_snapshots(ranking_snapshot_id) ON DELETE RESTRICT,
    rank_no             smallint NOT NULL CHECK (rank_no BETWEEN 1 AND 50),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    price_change        numeric(20,10) NOT NULL,
    reference_open_price numeric(38,18),
    snapshot_price      numeric(38,18),
    base_volume         numeric(38,18),
    quote_volume        numeric(38,18),
    amplitude           numeric(20,10),
    period_high_price   numeric(38,18),
    period_high_at      timestamptz,
    period_low_price    numeric(38,18),
    period_low_at       timestamptz,
    open_interest_qty   numeric(38,18),
    open_interest_value numeric(38,18),
    oi_change_5m        numeric(20,10),
    oi_change_15m       numeric(20,10),
    oi_change_1h        numeric(20,10),
    oi_change_24h       numeric(20,10),
    metrics             jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (ranking_snapshot_id, rank_no),
    UNIQUE (ranking_snapshot_id, instrument_id)
);

CREATE TABLE IF NOT EXISTS market.decision_snapshots (
    snapshot_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    interval_seconds    integer NOT NULL CHECK (interval_seconds >= 60),
    decision_time       timestamptz NOT NULL,
    source              varchar(16) NOT NULL CHECK (source IN ('LIVE','REPLAY','BACKTEST','SHADOW')),
    source_event_ids    uuid[] NOT NULL,
    snapshot_hash       char(64) NOT NULL,
    market_data         jsonb NOT NULL,
    reference_market    jsonb NOT NULL,
    exchange_rules      jsonb NOT NULL,
    quality_summary     jsonb NOT NULL,
    ready_at            timestamptz NOT NULL,
    node_id             varchar(80) NOT NULL,
    shard_id            varchar(80) NOT NULL DEFAULT '0',
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (instrument_id, interval_seconds, decision_time, source, snapshot_hash)
);

CREATE INDEX IF NOT EXISTS ix_decision_snapshots_time
ON market.decision_snapshots (decision_time DESC, instrument_id);

CREATE TABLE IF NOT EXISTS market.data_gaps (
    gap_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    instrument_id       bigint REFERENCES core.instruments(instrument_id),
    data_type           varchar(48) NOT NULL,
    interval_seconds    integer,
    gap_start           timestamptz NOT NULL,
    gap_end             timestamptz NOT NULL,
    expected_count      bigint,
    actual_count        bigint,
    status              varchar(24) NOT NULL CHECK (status IN ('OPEN','QUEUED','BACKFILLING','VERIFIED','UNAVAILABLE','QUARANTINED')),
    detected_at         timestamptz NOT NULL,
    resolved_at         timestamptz,
    reason_code         varchar(64),
    details             jsonb NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE NULLS NOT DISTINCT (instrument_id, data_type, interval_seconds, gap_start, gap_end),
    CHECK (gap_end > gap_start)
);

CREATE TABLE IF NOT EXISTS market.data_revisions (
    data_revision_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    instrument_id       bigint REFERENCES core.instruments(instrument_id),
    data_type           varchar(48) NOT NULL,
    business_key        jsonb NOT NULL,
    old_version         jsonb NOT NULL,
    new_version         jsonb NOT NULL,
    field_differences   jsonb NOT NULL,
    old_payload_hash    char(64) NOT NULL,
    new_payload_hash    char(64) NOT NULL,
    source_conflict     boolean NOT NULL DEFAULT false,
    reason_code         varchar(80) NOT NULL,
    discovered_at       timestamptz NOT NULL,
    effective_at        timestamptz,
    status              varchar(24) NOT NULL CHECK (status IN ('DETECTED','VERIFYING','QUARANTINED','APPROVED','REJECTED','APPLIED')),
    approved_by         text,
    evidence            jsonb NOT NULL DEFAULT '{}'::jsonb,
    affected_objects    jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (data_type, old_payload_hash, new_payload_hash)
);

CREATE TABLE IF NOT EXISTS market.backfill_jobs (
    backfill_job_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    gap_id              uuid REFERENCES market.data_gaps(gap_id),
    instrument_id       bigint REFERENCES core.instruments(instrument_id),
    data_type           varchar(48) NOT NULL,
    range_start         timestamptz NOT NULL,
    range_end           timestamptz NOT NULL,
    source_priority     jsonb NOT NULL,
    status              varchar(24) NOT NULL CHECK (status IN ('PENDING','RUNNING','PAUSED','SUCCEEDED','PARTIAL','FAILED','CANCELLED')),
    cursor_state        jsonb NOT NULL DEFAULT '{}'::jsonb,
    attempts            integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
    owner_instance_id   uuid REFERENCES core.service_instances(instance_id),
    ownership_epoch     bigint NOT NULL DEFAULT 0 CHECK (ownership_epoch >= 0),
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at          timestamptz,
    finished_at         timestamptz,
    error_details       jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (range_end > range_start)
);

CREATE INDEX IF NOT EXISTS ix_backfill_jobs_queue
ON market.backfill_jobs (status, created_at);

CREATE TABLE IF NOT EXISTS market.dataset_versions (
    dataset_version_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_name        varchar(120) NOT NULL,
    cutoff_at           timestamptz NOT NULL,
    universe_definition jsonb NOT NULL,
    source_versions     jsonb NOT NULL,
    coverage_summary    jsonb NOT NULL,
    quality_status      varchar(24) NOT NULL CHECK (quality_status IN ('BUILDING','VALID','DEGRADED','INVALID','REVOKED')),
    manifest_uri        text,
    manifest_hash       char(64) NOT NULL,
    created_by          text NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (dataset_name, manifest_hash)
);

CREATE TABLE IF NOT EXISTS market.data_coverage (
    coverage_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_version_id  uuid REFERENCES market.dataset_versions(dataset_version_id),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    data_type           varchar(48) NOT NULL,
    interval_seconds    integer,
    coverage_start      timestamptz,
    coverage_end        timestamptz,
    expected_count      bigint,
    actual_count        bigint,
    completeness_ratio numeric(12,10),
    source_types        text[] NOT NULL DEFAULT '{}',
    archive_files       jsonb NOT NULL DEFAULT '[]'::jsonb,
    source_checksums    jsonb NOT NULL DEFAULT '{}'::jsonb,
    gap_count           bigint NOT NULL DEFAULT 0,
    unavailable_ranges  jsonb NOT NULL DEFAULT '[]'::jsonb,
    quality_status      varchar(32) NOT NULL,
    audited_at          timestamptz NOT NULL,
    UNIQUE NULLS NOT DISTINCT (dataset_version_id, instrument_id, data_type, interval_seconds),
    CHECK (completeness_ratio IS NULL OR completeness_ratio BETWEEN 0 AND 1),
    CHECK (coverage_end IS NULL OR coverage_start IS NULL OR coverage_end >= coverage_start)
);

-- Immutable versioned configuration. Parameters are validated by each layer's JSON Schema.
CREATE TABLE IF NOT EXISTS config.component_versions (
    component_version_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    component_type       varchar(32) NOT NULL CHECK (component_type IN ('SIGNAL','MARKET_RISK','ACCOUNT_RISK','EXECUTION','EXIT','JEV','FEE','DATA_RULE')),
    component_key        varchar(120) NOT NULL,
    version_no           integer NOT NULL CHECK (version_no > 0),
    status               varchar(24) NOT NULL CHECK (status IN ('DRAFT','VALIDATED','APPROVED','RETIRED','REVOKED')),
    parameters           jsonb NOT NULL,
    schema_version       varchar(32) NOT NULL,
    code_version         varchar(80) NOT NULL,
    content_hash         char(64) NOT NULL,
    effective_from       timestamptz,
    effective_to         timestamptz,
    created_by           text NOT NULL,
    approved_by          text,
    approval_note        text,
    created_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
    approved_at          timestamptz,
    UNIQUE (component_type, component_key, version_no),
    UNIQUE (component_type, component_key, content_hash),
    CHECK ((status <> 'APPROVED') OR (approved_by IS NOT NULL AND approved_at IS NOT NULL)),
    CHECK (effective_to IS NULL OR effective_from IS NULL OR effective_to > effective_from)
);

CREATE TABLE IF NOT EXISTS config.release_bundles (
    release_bundle_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    release_key         varchar(120) NOT NULL,
    version_no          integer NOT NULL CHECK (version_no > 0),
    environment         varchar(16) NOT NULL CHECK (environment IN ('TEST','SHADOW','CANARY','PROD')),
    signal_version_id   uuid NOT NULL REFERENCES config.component_versions(component_version_id),
    market_risk_version_id uuid NOT NULL REFERENCES config.component_versions(component_version_id),
    account_risk_version_id uuid NOT NULL REFERENCES config.component_versions(component_version_id),
    execution_version_id uuid NOT NULL REFERENCES config.component_versions(component_version_id),
    exit_version_id     uuid NOT NULL REFERENCES config.component_versions(component_version_id),
    jev_version_id      uuid REFERENCES config.component_versions(component_version_id),
    fee_version_id      uuid NOT NULL REFERENCES config.component_versions(component_version_id),
    status              varchar(24) NOT NULL CHECK (status IN ('DRAFT','VALIDATED','APPROVED','DEPLOYED','RETIRED','REVOKED')),
    content_hash        char(64) NOT NULL,
    validation_evidence jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_by          text NOT NULL,
    approved_by         text,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    approved_at         timestamptz,
    UNIQUE (release_key, version_no, environment),
    UNIQUE (content_hash, environment),
    CHECK ((status NOT IN ('APPROVED','DEPLOYED')) OR (approved_by IS NOT NULL AND approved_at IS NOT NULL))
);

CREATE TABLE IF NOT EXISTS config.account_strategy_bindings (
    binding_id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          uuid NOT NULL REFERENCES core.exchange_accounts(account_id),
    release_bundle_id   uuid NOT NULL REFERENCES config.release_bundles(release_bundle_id),
    valid_from          timestamptz NOT NULL,
    valid_to            timestamptz,
    status              varchar(16) NOT NULL CHECK (status IN ('SCHEDULED','ACTIVE','PAUSED','ENDED')),
    created_by          text NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_one_active_strategy_per_account
ON config.account_strategy_bindings (account_id)
WHERE status = 'ACTIVE';

CREATE TABLE IF NOT EXISTS config.runtime_config_snapshots (
    runtime_config_snapshot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          uuid REFERENCES core.exchange_accounts(account_id),
    release_bundle_id   uuid REFERENCES config.release_bundles(release_bundle_id),
    environment         varchar(16) NOT NULL,
    resolved_config     jsonb NOT NULL,
    content_hash        char(64) NOT NULL,
    captured_at         timestamptz NOT NULL,
    service_instance_id uuid REFERENCES core.service_instances(instance_id),
    UNIQUE (environment, content_hash)
);

CREATE TABLE IF NOT EXISTS trade.account_snapshots (
    account_snapshot_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          uuid NOT NULL REFERENCES core.exchange_accounts(account_id),
    snapshot_time       timestamptz NOT NULL,
    exchange_update_time timestamptz,
    wallet_balance      numeric(38,18) NOT NULL,
    margin_balance      numeric(38,18) NOT NULL,
    available_balance   numeric(38,18) NOT NULL,
    total_initial_margin numeric(38,18) NOT NULL,
    total_maintenance_margin numeric(38,18) NOT NULL,
    total_unrealized_pnl numeric(38,18) NOT NULL,
    margin_ratio        numeric(20,12),
    positions           jsonb NOT NULL,
    open_orders         jsonb NOT NULL,
    source_event_ids    uuid[] NOT NULL DEFAULT '{}',
    snapshot_hash       char(64) NOT NULL,
    quality_status      varchar(24) NOT NULL CHECK (quality_status IN ('VALID','DEGRADED','INVALID','STALE')),
    collected_at        timestamptz NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (account_id, snapshot_time, snapshot_hash)
);

CREATE INDEX IF NOT EXISTS ix_account_snapshots_latest
ON trade.account_snapshots (account_id, snapshot_time DESC);

CREATE TABLE IF NOT EXISTS trade.cash_flows (
    cash_flow_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          uuid NOT NULL REFERENCES core.exchange_accounts(account_id),
    exchange_transaction_id varchar(120) NOT NULL,
    flow_type           varchar(32) NOT NULL CHECK (flow_type IN ('DEPOSIT','WITHDRAWAL','TRANSFER_IN','TRANSFER_OUT','COMMISSION','FUNDING_FEE','REALIZED_PNL','ADJUSTMENT')),
    asset               varchar(24) NOT NULL,
    amount              numeric(38,18) NOT NULL,
    effective_at        timestamptz NOT NULL,
    discovered_at       timestamptz NOT NULL,
    raw_event_id        uuid,
    metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
    UNIQUE (account_id, exchange_transaction_id, flow_type)
);

CREATE TABLE IF NOT EXISTS trade.decision_contexts (
    decision_context_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    correlation_id      uuid NOT NULL,
    account_id          uuid REFERENCES core.exchange_accounts(account_id),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    market_snapshot_id  uuid NOT NULL REFERENCES market.decision_snapshots(snapshot_id),
    account_snapshot_id uuid REFERENCES trade.account_snapshots(account_snapshot_id),
    release_bundle_id   uuid REFERENCES config.release_bundles(release_bundle_id),
    decision_time       timestamptz NOT NULL,
    context_payload     jsonb NOT NULL,
    context_hash        char(64) NOT NULL,
    source              varchar(16) NOT NULL CHECK (source IN ('LIVE','REPLAY','BACKTEST','SHADOW')),
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (correlation_id, context_hash)
);

CREATE TABLE IF NOT EXISTS trade.signals (
    signal_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    decision_context_id uuid NOT NULL REFERENCES trade.decision_contexts(decision_context_id),
    signal_version_id   uuid NOT NULL REFERENCES config.component_versions(component_version_id),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    side                varchar(8) NOT NULL CHECK (side IN ('LONG','SHORT')),
    signal_time         timestamptz NOT NULL,
    valid_until         timestamptz NOT NULL,
    triggered           boolean NOT NULL,
    alpha_score         numeric(20,10),
    reason_codes        text[] NOT NULL DEFAULT '{}',
    evaluation          jsonb NOT NULL,
    idempotency_key     varchar(160) NOT NULL UNIQUE,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (valid_until >= signal_time)
);

CREATE INDEX IF NOT EXISTS ix_signals_time_instrument
ON trade.signals (signal_time DESC, instrument_id);

CREATE TABLE IF NOT EXISTS trade.layer_decisions (
    layer_decision_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    decision_context_id uuid NOT NULL REFERENCES trade.decision_contexts(decision_context_id),
    signal_id           uuid REFERENCES trade.signals(signal_id),
    layer_type          varchar(32) NOT NULL CHECK (layer_type IN ('SIGNAL','MARKET_RISK','ACCOUNT_RISK','ROTATION','EXECUTION','EXIT')),
    component_version_id uuid NOT NULL REFERENCES config.component_versions(component_version_id),
    sequence_no         smallint NOT NULL CHECK (sequence_no > 0),
    outcome             varchar(24) NOT NULL CHECK (outcome IN ('PASS','VETO','DEFER','SKIP','ERROR','ACTION')),
    primary_reason_code varchar(80),
    all_reason_codes    text[] NOT NULL DEFAULT '{}',
    inputs              jsonb NOT NULL,
    outputs             jsonb NOT NULL,
    decided_at          timestamptz NOT NULL,
    duration_ms         integer CHECK (duration_ms >= 0),
    UNIQUE (decision_context_id, layer_type, sequence_no)
);

CREATE TABLE IF NOT EXISTS trade.jev_decisions (
    jev_decision_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    decision_context_id uuid NOT NULL REFERENCES trade.decision_contexts(decision_context_id),
    jev_version_id      uuid NOT NULL REFERENCES config.component_versions(component_version_id),
    mode                varchar(16) NOT NULL CHECK (mode IN ('SHADOW','ENFORCE')),
    model_provider      varchar(80) NOT NULL,
    model_name          varchar(120) NOT NULL,
    prompt_hash         char(64) NOT NULL,
    input_hash          char(64) NOT NULL,
    verdict             varchar(24) NOT NULL CHECK (verdict IN ('ALLOW','VETO','UNKNOWN','ERROR')),
    confidence          numeric(10,8),
    reason_codes        text[] NOT NULL DEFAULT '{}',
    request_payload     jsonb NOT NULL,
    response_payload    jsonb,
    started_at          timestamptz NOT NULL,
    completed_at        timestamptz,
    duration_ms         integer,
    error_code          varchar(80),
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (confidence IS NULL OR confidence BETWEEN 0 AND 1)
);

CREATE TABLE IF NOT EXISTS trade.risk_reservations (
    risk_reservation_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          uuid NOT NULL REFERENCES core.exchange_accounts(account_id),
    signal_id           uuid REFERENCES trade.signals(signal_id),
    reservation_key     varchar(160) NOT NULL UNIQUE,
    status              varchar(24) NOT NULL CHECK (status IN ('HELD','CONSUMED','RELEASED','EXPIRED','CANCELLED')),
    reserved_notional   numeric(38,18) NOT NULL CHECK (reserved_notional >= 0),
    reserved_initial_margin numeric(38,18) NOT NULL CHECK (reserved_initial_margin >= 0),
    reserved_risk_amount numeric(38,18) NOT NULL CHECK (reserved_risk_amount >= 0),
    projected_margin_ratio numeric(20,12),
    safety_epoch        bigint NOT NULL CHECK (safety_epoch >= 0),
    held_at             timestamptz NOT NULL,
    expires_at          timestamptz NOT NULL,
    released_at         timestamptz,
    details             jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (expires_at > held_at)
);

DROP TRIGGER IF EXISTS trg_risk_reservations_updated_at ON trade.risk_reservations;
CREATE TRIGGER trg_risk_reservations_updated_at
BEFORE UPDATE ON trade.risk_reservations
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE INDEX IF NOT EXISTS ix_risk_reservations_account_status
ON trade.risk_reservations (account_id, status, expires_at);

CREATE TABLE IF NOT EXISTS trade.order_intents (
    order_intent_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          uuid NOT NULL REFERENCES core.exchange_accounts(account_id),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    signal_id           uuid REFERENCES trade.signals(signal_id),
    decision_context_id uuid NOT NULL REFERENCES trade.decision_contexts(decision_context_id),
    risk_reservation_id uuid REFERENCES trade.risk_reservations(risk_reservation_id),
    parent_intent_id    uuid REFERENCES trade.order_intents(order_intent_id),
    intent_type         varchar(32) NOT NULL CHECK (intent_type IN ('OPEN','REDUCE','CLOSE','STOP_PROTECTION','TAKE_PROFIT','CANCEL','RECONCILE')),
    side                varchar(8) NOT NULL CHECK (side IN ('BUY','SELL')),
    position_side       varchar(8) NOT NULL CHECK (position_side IN ('LONG','SHORT','BOTH')),
    order_type          varchar(24) NOT NULL CHECK (order_type IN ('MARKET','LIMIT','STOP_MARKET','TAKE_PROFIT','TAKE_PROFIT_MARKET')),
    time_in_force       varchar(8),
    requested_quantity  numeric(38,18) NOT NULL CHECK (requested_quantity > 0),
    requested_price     numeric(38,18),
    stop_price          numeric(38,18),
    reduce_only         boolean NOT NULL DEFAULT false,
    close_position      boolean NOT NULL DEFAULT false,
    rule_version_id     uuid NOT NULL REFERENCES core.instrument_rule_versions(rule_version_id),
    safety_epoch        bigint NOT NULL CHECK (safety_epoch >= 0),
    idempotency_key     varchar(160) NOT NULL UNIQUE,
    status              varchar(24) NOT NULL CHECK (status IN ('CREATED','AUTHORIZED','SUBMITTING','SUBMITTED','REJECTED','UNKNOWN','CANCELLED','COMPLETED')),
    reason_code         varchar(80),
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (requested_price IS NULL OR requested_price > 0),
    CHECK (stop_price IS NULL OR stop_price > 0),
    CHECK (intent_type <> 'OPEN' OR NOT reduce_only)
);

DROP TRIGGER IF EXISTS trg_order_intents_updated_at ON trade.order_intents;
CREATE TRIGGER trg_order_intents_updated_at
BEFORE UPDATE ON trade.order_intents
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE INDEX IF NOT EXISTS ix_order_intents_account_status
ON trade.order_intents (account_id, status, created_at DESC);

CREATE TABLE IF NOT EXISTS trade.orders (
    order_pk            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_intent_id     uuid NOT NULL REFERENCES trade.order_intents(order_intent_id),
    account_id          uuid NOT NULL REFERENCES core.exchange_accounts(account_id),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    exchange_order_id   varchar(80),
    client_order_id     varchar(80) NOT NULL,
    order_type          varchar(24) NOT NULL,
    side                varchar(8) NOT NULL CHECK (side IN ('BUY','SELL')),
    position_side       varchar(8) NOT NULL CHECK (position_side IN ('LONG','SHORT','BOTH')),
    original_quantity   numeric(38,18) NOT NULL CHECK (original_quantity > 0),
    executed_quantity   numeric(38,18) NOT NULL DEFAULT 0 CHECK (executed_quantity >= 0),
    average_price       numeric(38,18),
    limit_price         numeric(38,18),
    stop_price          numeric(38,18),
    status              varchar(32) NOT NULL,
    reduce_only         boolean NOT NULL,
    close_position      boolean NOT NULL,
    exchange_created_at timestamptz,
    exchange_updated_at timestamptz,
    submitted_at        timestamptz,
    terminal_at         timestamptz,
    last_reconciled_at  timestamptz,
    raw_response        jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (account_id, client_order_id),
    UNIQUE NULLS NOT DISTINCT (account_id, exchange_order_id),
    CHECK (executed_quantity <= original_quantity)
);

DROP TRIGGER IF EXISTS trg_orders_updated_at ON trade.orders;
CREATE TRIGGER trg_orders_updated_at
BEFORE UPDATE ON trade.orders
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE INDEX IF NOT EXISTS ix_orders_active
ON trade.orders (account_id, status, instrument_id)
WHERE terminal_at IS NULL;

CREATE TABLE IF NOT EXISTS trade.order_events (
    order_event_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_pk            uuid NOT NULL REFERENCES trade.orders(order_pk),
    event_type          varchar(48) NOT NULL,
    exchange_event_id   varchar(120),
    exchange_event_time timestamptz,
    received_at         timestamptz NOT NULL,
    order_status        varchar(32),
    executed_quantity   numeric(38,18),
    payload             jsonb NOT NULL,
    payload_hash        char(64) NOT NULL,
    UNIQUE NULLS NOT DISTINCT (order_pk, exchange_event_id, event_type, payload_hash)
);

CREATE INDEX IF NOT EXISTS ix_order_events_order_time
ON trade.order_events (order_pk, received_at);

CREATE TABLE IF NOT EXISTS trade.fills (
    fill_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_pk            uuid NOT NULL REFERENCES trade.orders(order_pk),
    account_id          uuid NOT NULL REFERENCES core.exchange_accounts(account_id),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    exchange_trade_id   varchar(120) NOT NULL,
    side                varchar(8) NOT NULL CHECK (side IN ('BUY','SELL')),
    position_side       varchar(8) NOT NULL CHECK (position_side IN ('LONG','SHORT','BOTH')),
    price               numeric(38,18) NOT NULL CHECK (price > 0),
    quantity            numeric(38,18) NOT NULL CHECK (quantity > 0),
    quote_amount        numeric(38,18) NOT NULL CHECK (quote_amount >= 0),
    realized_pnl        numeric(38,18),
    commission_amount   numeric(38,18),
    commission_asset    varchar(24),
    is_maker            boolean,
    fill_time           timestamptz NOT NULL,
    received_at         timestamptz NOT NULL,
    raw_payload         jsonb NOT NULL,
    UNIQUE (account_id, exchange_trade_id)
);

CREATE INDEX IF NOT EXISTS ix_fills_account_time
ON trade.fills (account_id, fill_time DESC);

CREATE INDEX IF NOT EXISTS ix_fills_instrument_time
ON trade.fills (instrument_id, fill_time DESC);

CREATE TABLE IF NOT EXISTS trade.position_lifecycles (
    position_lifecycle_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          uuid NOT NULL REFERENCES core.exchange_accounts(account_id),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    release_bundle_id   uuid REFERENCES config.release_bundles(release_bundle_id),
    opening_signal_id   uuid REFERENCES trade.signals(signal_id),
    position_side       varchar(8) NOT NULL CHECK (position_side IN ('LONG','SHORT')),
    status              varchar(24) NOT NULL CHECK (status IN ('OPENING','OPEN','REDUCING','CLOSING','CLOSED','RECONCILING','INVALID')),
    opened_at           timestamptz NOT NULL,
    closed_at           timestamptz,
    entry_vwap          numeric(38,18),
    exit_vwap           numeric(38,18),
    initial_quantity    numeric(38,18),
    max_quantity        numeric(38,18),
    final_quantity      numeric(38,18) NOT NULL DEFAULT 0,
    initial_notional    numeric(38,18),
    gross_realized_pnl  numeric(38,18),
    net_realized_pnl    numeric(38,18),
    commission_total    numeric(38,18),
    funding_total       numeric(38,18),
    holding_mfe_gross   numeric(38,18),
    holding_mfe_rate    numeric(20,12),
    holding_mfe_at      timestamptz,
    holding_mae_gross   numeric(38,18),
    holding_mae_rate    numeric(20,12),
    holding_mae_at      timestamptz,
    final_gross_rate    numeric(20,12),
    profit_realization_status varchar(32) NOT NULL DEFAULT 'NOT_APPLICABLE' CHECK (profit_realization_status IN ('NOT_APPLICABLE','CALCULATED','NO_POSITIVE_MFE','CALCULATION_ERROR')),
    profit_realization_ratio numeric(20,12),
    profit_to_loss      boolean NOT NULL DEFAULT false,
    metric_rule_version varchar(64),
    metric_calculated_at timestamptz,
    data_complete       boolean NOT NULL DEFAULT true,
    exclusion_reasons   text[] NOT NULL DEFAULT '{}',
    protection_until    timestamptz,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (closed_at IS NULL OR closed_at >= opened_at),
    CHECK (profit_realization_ratio IS NULL OR profit_realization_ratio BETWEEN 0 AND 1.000001),
    CHECK ((status <> 'CLOSED') OR (closed_at IS NOT NULL AND final_quantity = 0)),
    CHECK ((profit_realization_status <> 'CALCULATED') OR (status = 'CLOSED' AND metric_calculated_at IS NOT NULL AND profit_realization_ratio IS NOT NULL)),
    CHECK ((status = 'CLOSED') OR (profit_realization_status = 'NOT_APPLICABLE'))
);

DROP TRIGGER IF EXISTS trg_position_lifecycles_updated_at ON trade.position_lifecycles;
CREATE TRIGGER trg_position_lifecycles_updated_at
BEFORE UPDATE ON trade.position_lifecycles
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE UNIQUE INDEX IF NOT EXISTS ux_open_position_lifecycle
ON trade.position_lifecycles (account_id, instrument_id, position_side)
WHERE status IN ('OPENING','OPEN','REDUCING','CLOSING','RECONCILING');

CREATE INDEX IF NOT EXISTS ix_positions_account_status
ON trade.position_lifecycles (account_id, status, opened_at DESC);

CREATE TABLE IF NOT EXISTS trade.position_fill_links (
    position_lifecycle_id uuid NOT NULL REFERENCES trade.position_lifecycles(position_lifecycle_id),
    fill_id             uuid NOT NULL REFERENCES trade.fills(fill_id),
    fill_role           varchar(16) NOT NULL CHECK (fill_role IN ('OPEN','ADD','REDUCE','CLOSE','REVERSAL')),
    quantity_effect     numeric(38,18) NOT NULL,
    PRIMARY KEY (position_lifecycle_id, fill_id)
);

CREATE TABLE IF NOT EXISTS trade.position_events (
    position_event_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    position_lifecycle_id uuid NOT NULL REFERENCES trade.position_lifecycles(position_lifecycle_id),
    event_type          varchar(48) NOT NULL,
    event_time          timestamptz NOT NULL,
    quantity_before     numeric(38,18),
    quantity_after      numeric(38,18),
    gross_pnl_at_event  numeric(38,18),
    reason_code         varchar(80),
    source              varchar(24) NOT NULL,
    payload             jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS ix_position_events_lifecycle_time
ON trade.position_events (position_lifecycle_id, event_time);

CREATE TABLE IF NOT EXISTS trade.position_metric_points (
    position_lifecycle_id uuid NOT NULL REFERENCES trade.position_lifecycles(position_lifecycle_id),
    point_time          timestamptz NOT NULL,
    position_quantity   numeric(38,18) NOT NULL,
    last_price          numeric(38,18) NOT NULL,
    mark_price          numeric(38,18),
    cumulative_realized_gross numeric(38,18) NOT NULL,
    remaining_unrealized_gross numeric(38,18) NOT NULL,
    whole_position_gross numeric(38,18) NOT NULL,
    whole_position_gross_rate numeric(20,12),
    net_pnl             numeric(38,18),
    source_ticker_time  timestamptz NOT NULL,
    quality_status      varchar(24) NOT NULL,
    PRIMARY KEY (position_lifecycle_id, point_time)
);

SELECT create_hypertable('trade.position_metric_points', by_range('point_time'), if_not_exists => TRUE);

CREATE TABLE IF NOT EXISTS trade.safety_states (
    safety_state_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    safety_scope_type   varchar(16) NOT NULL CHECK (safety_scope_type IN ('SYSTEM','ACCOUNT')),
    account_id          uuid REFERENCES core.exchange_accounts(account_id),
    safety_epoch        bigint NOT NULL CHECK (safety_epoch >= 0),
    state               varchar(24) NOT NULL CHECK (state IN ('NORMAL','ENTRY_PAUSED','REDUCE_ONLY','P0_LATCHED','RECOVERING')),
    primary_reason_code varchar(80),
    reason_details      jsonb NOT NULL DEFAULT '{}'::jsonb,
    latched_at          timestamptz,
    last_verified_at    timestamptz,
    unlocked_at         timestamptz,
    unlocked_by         text,
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK ((safety_scope_type = 'SYSTEM' AND account_id IS NULL) OR (safety_scope_type = 'ACCOUNT' AND account_id IS NOT NULL)),
    CHECK ((state <> 'P0_LATCHED') OR latched_at IS NOT NULL)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_safety_current_system
ON trade.safety_states (safety_scope_type)
WHERE safety_scope_type = 'SYSTEM' AND unlocked_at IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_safety_current_account
ON trade.safety_states (account_id)
WHERE safety_scope_type = 'ACCOUNT' AND unlocked_at IS NULL;

CREATE TABLE IF NOT EXISTS trade.safety_state_events (
    safety_event_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    safety_state_id     uuid NOT NULL REFERENCES trade.safety_states(safety_state_id),
    account_id          uuid REFERENCES core.exchange_accounts(account_id),
    safety_epoch        bigint NOT NULL CHECK (safety_epoch >= 0),
    previous_state      varchar(24),
    new_state           varchar(24) NOT NULL,
    reason_code         varchar(80) NOT NULL,
    actor_type          varchar(24) NOT NULL,
    actor_id            text NOT NULL,
    evidence            jsonb NOT NULL DEFAULT '{}'::jsonb,
    event_time          timestamptz NOT NULL,
    correlation_id      uuid,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (safety_state_id, safety_epoch)
);

CREATE TABLE IF NOT EXISTS trade.outbox_events (
    outbox_event_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_type      varchar(48) NOT NULL,
    aggregate_id        text NOT NULL,
    event_type          varchar(80) NOT NULL,
    schema_version      smallint NOT NULL CHECK (schema_version > 0),
    event_payload       jsonb NOT NULL,
    event_hash          char(64) NOT NULL,
    safety_epoch        bigint,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    available_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    published_at        timestamptz,
    publish_attempts    integer NOT NULL DEFAULT 0 CHECK (publish_attempts >= 0),
    last_error          text,
    UNIQUE (aggregate_type, aggregate_id, event_type, event_hash)
);

CREATE INDEX IF NOT EXISTS ix_outbox_pending
ON trade.outbox_events (available_at, created_at)
WHERE published_at IS NULL;

CREATE TABLE IF NOT EXISTS trade.account_leases (
    account_id          uuid PRIMARY KEY REFERENCES core.exchange_accounts(account_id),
    owner_instance_id   uuid NOT NULL REFERENCES core.service_instances(instance_id),
    fencing_token       bigint NOT NULL CHECK (fencing_token > 0),
    acquired_at         timestamptz NOT NULL,
    renewed_at          timestamptz NOT NULL,
    expires_at          timestamptz NOT NULL,
    CHECK (expires_at > renewed_at)
);

CREATE TABLE IF NOT EXISTS trade.reconciliation_runs (
    reconciliation_run_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          uuid NOT NULL REFERENCES core.exchange_accounts(account_id),
    trigger_type        varchar(32) NOT NULL,
    started_at          timestamptz NOT NULL,
    completed_at        timestamptz,
    status              varchar(24) NOT NULL CHECK (status IN ('RUNNING','MATCHED','MISMATCH','FAILED','REQUIRES_REVIEW')),
    exchange_snapshot   jsonb NOT NULL,
    local_snapshot      jsonb NOT NULL,
    differences         jsonb NOT NULL DEFAULT '[]'::jsonb,
    actions_taken       jsonb NOT NULL DEFAULT '[]'::jsonb,
    safety_epoch        bigint NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE INDEX IF NOT EXISTS ix_reconciliation_account_time
ON trade.reconciliation_runs (account_id, started_at DESC);

CREATE TABLE IF NOT EXISTS analysis.experiments (
    experiment_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_name     varchar(160) NOT NULL,
    objective           text NOT NULL,
    dataset_version_id  uuid NOT NULL REFERENCES market.dataset_versions(dataset_version_id),
    baseline_release_bundle_id uuid REFERENCES config.release_bundles(release_bundle_id),
    evaluation_start    timestamptz NOT NULL,
    evaluation_end      timestamptz NOT NULL,
    warmup_start        timestamptz NOT NULL,
    split_definition    jsonb NOT NULL,
    cost_scenarios      jsonb NOT NULL,
    status              varchar(24) NOT NULL CHECK (status IN ('DRAFT','QUEUED','RUNNING','COMPLETED','FAILED','CANCELLED','INVALIDATED')),
    created_by          text NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (warmup_start < evaluation_start),
    CHECK (evaluation_end > evaluation_start)
);

CREATE TABLE IF NOT EXISTS analysis.parameter_sets (
    parameter_set_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id       uuid NOT NULL REFERENCES analysis.experiments(experiment_id) ON DELETE RESTRICT,
    component_versions  jsonb NOT NULL,
    parameter_overrides jsonb NOT NULL DEFAULT '{}'::jsonb,
    content_hash        char(64) NOT NULL,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (experiment_id, content_hash)
);

CREATE TABLE IF NOT EXISTS analysis.experiment_runs (
    experiment_run_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id       uuid NOT NULL REFERENCES analysis.experiments(experiment_id) ON DELETE RESTRICT,
    parameter_set_id    uuid NOT NULL REFERENCES analysis.parameter_sets(parameter_set_id),
    run_mode            varchar(24) NOT NULL CHECK (run_mode IN ('SIGNAL_ONLY','RISK_ONLY','FULL_PORTFOLIO','EXIT_ONLY','REPLAY','SHADOW_COMPARE')),
    random_seed         bigint NOT NULL,
    engine_version      varchar(80) NOT NULL,
    runtime_config_hash char(64) NOT NULL,
    status              varchar(24) NOT NULL CHECK (status IN ('QUEUED','RUNNING','PAUSED','COMPLETED','FAILED','CANCELLED','INVALID')),
    owner_instance_id   uuid REFERENCES core.service_instances(instance_id),
    started_at          timestamptz,
    finished_at         timestamptz,
    result_hash         char(64),
    error_details       jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (experiment_id, parameter_set_id, run_mode, random_seed, engine_version)
);

CREATE INDEX IF NOT EXISTS ix_experiment_runs_queue
ON analysis.experiment_runs (status, created_at);

CREATE TABLE IF NOT EXISTS analysis.run_metrics (
    experiment_run_id   uuid NOT NULL REFERENCES analysis.experiment_runs(experiment_run_id) ON DELETE RESTRICT,
    metric_scope        varchar(32) NOT NULL,
    scope_key           varchar(160) NOT NULL DEFAULT 'ALL',
    metric_name         varchar(120) NOT NULL,
    metric_value        numeric(38,18),
    metric_text         text,
    sample_count        bigint,
    metric_rule_version varchar(64) NOT NULL,
    details             jsonb NOT NULL DEFAULT '{}'::jsonb,
    PRIMARY KEY (experiment_run_id, metric_scope, scope_key, metric_name)
);

CREATE TABLE IF NOT EXISTS analysis.simulated_trades (
    simulated_trade_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_run_id   uuid NOT NULL REFERENCES analysis.experiment_runs(experiment_run_id) ON DELETE RESTRICT,
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    signal_id           uuid,
    side                varchar(8) NOT NULL CHECK (side IN ('LONG','SHORT')),
    opened_at           timestamptz NOT NULL,
    closed_at           timestamptz,
    entry_price         numeric(38,18) NOT NULL,
    exit_price          numeric(38,18),
    initial_quantity    numeric(38,18) NOT NULL,
    gross_pnl           numeric(38,18),
    net_pnl             numeric(38,18),
    commission_total    numeric(38,18),
    funding_total       numeric(38,18),
    slippage_total      numeric(38,18),
    holding_mfe_gross   numeric(38,18),
    holding_mfe_rate    numeric(20,12),
    holding_mae_gross   numeric(38,18),
    holding_mae_rate    numeric(20,12),
    profit_realization_status varchar(32),
    profit_realization_ratio numeric(20,12),
    profit_to_loss      boolean NOT NULL DEFAULT false,
    exit_reason_code    varchar(80),
    data_quality        jsonb NOT NULL,
    details             jsonb NOT NULL DEFAULT '{}'::jsonb,
    CHECK (closed_at IS NULL OR closed_at >= opened_at),
    CHECK (profit_realization_ratio IS NULL OR profit_realization_ratio BETWEEN 0 AND 1.000001)
);

CREATE INDEX IF NOT EXISTS ix_simulated_trades_run
ON analysis.simulated_trades (experiment_run_id, opened_at);

CREATE TABLE IF NOT EXISTS analysis.super_market_events (
    super_market_event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    dataset_version_id  uuid NOT NULL REFERENCES market.dataset_versions(dataset_version_id),
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    event_version       varchar(64) NOT NULL,
    event_start         timestamptz NOT NULL,
    reference_price     numeric(38,18) NOT NULL,
    high_24h_price      numeric(38,18) NOT NULL,
    high_24h_at         timestamptz NOT NULL,
    return_24h          numeric(20,12) NOT NULL CHECK (return_24h >= 1.0),
    first_reached_100_at timestamptz NOT NULL,
    high_3d_price       numeric(38,18),
    high_3d_at          timestamptz,
    high_7d_price       numeric(38,18),
    high_7d_at          timestamptz,
    event_hash          char(64) NOT NULL,
    UNIQUE (dataset_version_id, instrument_id, event_hash)
);

CREATE TABLE IF NOT EXISTS analysis.signal_forward_labels (
    label_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_run_id   uuid REFERENCES analysis.experiment_runs(experiment_run_id),
    signal_id           uuid,
    instrument_id       bigint NOT NULL REFERENCES core.instruments(instrument_id),
    signal_time         timestamptz NOT NULL,
    signal_price        numeric(38,18) NOT NULL,
    alpha_window_seconds integer NOT NULL DEFAULT 2700,
    alpha_threshold     numeric(20,12) NOT NULL,
    alpha_success       boolean,
    high_24h_price      numeric(38,18),
    high_24h_at         timestamptz,
    forward_return_24h  numeric(20,12),
    is_super_instrument boolean,
    super_market_event_id uuid REFERENCES analysis.super_market_events(super_market_event_id),
    maturity_time       timestamptz NOT NULL,
    label_rule_version  varchar(64) NOT NULL,
    data_complete       boolean NOT NULL,
    UNIQUE NULLS NOT DISTINCT (experiment_run_id, signal_id, label_rule_version)
);

CREATE TABLE IF NOT EXISTS audit.audit_events (
    audit_event_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    event_time          timestamptz NOT NULL DEFAULT clock_timestamp(),
    actor_type          varchar(24) NOT NULL CHECK (actor_type IN ('USER','SERVICE','SYSTEM','EXCHANGE')),
    actor_id            text NOT NULL,
    action              varchar(120) NOT NULL,
    resource_type       varchar(80) NOT NULL,
    resource_id         text,
    correlation_id      uuid,
    source_ip           inet,
    before_hash         char(64),
    after_hash          char(64),
    reason              text,
    details             jsonb NOT NULL DEFAULT '{}'::jsonb,
    previous_event_hash char(64),
    event_hash          char(64) NOT NULL UNIQUE
);

CREATE INDEX IF NOT EXISTS ix_audit_events_resource_time
ON audit.audit_events (resource_type, resource_id, event_time DESC);

CREATE TABLE IF NOT EXISTS audit.alerts (
    alert_id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    severity            varchar(8) NOT NULL CHECK (severity IN ('P0','P1','P2','P3')),
    alert_type          varchar(80) NOT NULL,
    account_id          uuid REFERENCES core.exchange_accounts(account_id),
    instrument_id       bigint REFERENCES core.instruments(instrument_id),
    correlation_id      uuid,
    status              varchar(24) NOT NULL CHECK (status IN ('OPEN','ACKNOWLEDGED','RESOLVED','SUPPRESSED')),
    first_seen_at       timestamptz NOT NULL,
    last_seen_at        timestamptz NOT NULL,
    occurrence_count    bigint NOT NULL DEFAULT 1 CHECK (occurrence_count > 0),
    acknowledged_at     timestamptz,
    acknowledged_by     text,
    resolved_at         timestamptz,
    summary             text NOT NULL,
    details             jsonb NOT NULL DEFAULT '{}'::jsonb,
    deduplication_key   varchar(200) NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_alerts_active_dedup
ON audit.alerts (deduplication_key)
WHERE status IN ('OPEN','ACKNOWLEDGED');

-- Fixed system baselines only. Exit parameters are deliberately absent/TBD_BY_BACKTEST.
INSERT INTO config.component_versions (
    component_type, component_key, version_no, status, parameters,
    schema_version, code_version, content_hash, created_by
)
VALUES
(
    'ACCOUNT_RISK', 'account_safety_baseline', 1, 'DRAFT',
    '{"entry_margin_ratio_limit":"0.20","forced_reduce_trigger":"0.50","forced_reduce_recovery":"0.40","forced_reduce_fraction":"0.25","emergency_exit_trigger":"0.80"}'::jsonb,
    '1', 'TBD', encode(digest('account_safety_baseline_v1', 'sha256'), 'hex'), 'INITIAL_MIGRATION'
),
(
    'FEE', 'standard_fee_baseline', 1, 'DRAFT',
    '{"maker_rate":null,"taker_rate":null,"bnb_discount_assumed":false,"note":"Rates must be supplied and approved before use"}'::jsonb,
    '1', 'TBD', encode(digest('standard_fee_baseline_v1', 'sha256'), 'hex'), 'INITIAL_MIGRATION'
)
ON CONFLICT (component_type, component_key, version_no) DO NOTHING;

-- Group roles have no login/password. Deployment-created users inherit exactly one or more groups.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tb2_migration') THEN CREATE ROLE tb2_migration NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tb2_collector') THEN CREATE ROLE tb2_collector NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tb2_trader') THEN CREATE ROLE tb2_trader NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tb2_analysis_ro') THEN CREATE ROLE tb2_analysis_ro NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tb2_analysis_rw') THEN CREATE ROLE tb2_analysis_rw NOLOGIN; END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tb2_backup') THEN CREATE ROLE tb2_backup NOLOGIN; END IF;
END
$$;

REVOKE ALL ON SCHEMA core, config, market, trade, analysis, audit FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA core, config, market, trade, analysis, audit FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA core, config, market, trade, analysis, audit FROM PUBLIC;

GRANT USAGE ON SCHEMA core, market, audit TO tb2_collector;
GRANT SELECT ON core.instruments, core.instrument_rule_versions TO tb2_collector;
GRANT SELECT, INSERT, UPDATE ON core.instruments, core.instrument_rule_versions, core.service_instances TO tb2_collector;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA market TO tb2_collector;
REVOKE UPDATE ON market.raw_events, market.open_interest_observations,
    market.funding_observations, market.derivative_metrics_5m,
    market.supply_observations, market.data_revisions,
    market.dataset_versions, market.data_coverage
FROM tb2_collector;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA core, market TO tb2_collector;

GRANT USAGE ON SCHEMA core, config, market, trade, audit TO tb2_trader;
GRANT SELECT ON ALL TABLES IN SCHEMA core, config, market TO tb2_trader;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA trade, audit TO tb2_trader;
REVOKE UPDATE ON trade.cash_flows, trade.decision_contexts, trade.signals,
    trade.layer_decisions, trade.jev_decisions, trade.order_events,
    trade.fills, trade.position_fill_links, trade.position_events,
    trade.position_metric_points, trade.safety_state_events,
    trade.reconciliation_runs, audit.audit_events
FROM tb2_trader;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA core, config, market, trade, audit TO tb2_trader;

GRANT USAGE ON SCHEMA core, config, market, trade, audit TO tb2_analysis_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA core, config, market, trade, audit TO tb2_analysis_ro;

GRANT USAGE ON SCHEMA analysis TO tb2_analysis_rw;
GRANT SELECT, INSERT, UPDATE ON ALL TABLES IN SCHEMA analysis TO tb2_analysis_rw;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA analysis TO tb2_analysis_rw;
GRANT tb2_analysis_ro TO tb2_analysis_rw;

GRANT USAGE ON SCHEMA core, config, market, trade, analysis, audit TO tb2_backup;
GRANT SELECT ON ALL TABLES IN SCHEMA core, config, market, trade, analysis, audit TO tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '001_initial_schema',
    encode(digest('trading_bot_v2_001_initial_schema_draft_0276', 'sha256'), 'hex'),
    'Initial Trading Bot 2.0 schema for market, config, live trade, analysis and audit data'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
