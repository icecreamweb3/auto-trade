\set ON_ERROR_STOP on
\pset pager off

BEGIN;

-- Keep change discovery outside the compressed hypertables. Scanning
-- effective_at/collected_at across historical columnstore chunks for every
-- instrument can decompress a large part of the market dataset.
CREATE TABLE IF NOT EXISTS market.kline_15m_dirty_ranges (
    instrument_id  bigint PRIMARY KEY REFERENCES core.instruments(instrument_id),
    dirty_start    timestamptz NOT NULL,
    changed_at     timestamptz NOT NULL,
    updated_at     timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE IF NOT EXISTS market.kline_ema_dirty_ranges (
    instrument_id    bigint NOT NULL REFERENCES core.instruments(instrument_id),
    interval_seconds integer NOT NULL CHECK (interval_seconds IN (300, 900, 3600)),
    dirty_start      timestamptz NOT NULL,
    changed_at       timestamptz NOT NULL,
    updated_at       timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (instrument_id, interval_seconds)
);

CREATE OR REPLACE FUNCTION market.mark_kline_15m_dirty_from_kline()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.price_type = 'TRADE' AND NEW.interval_seconds = 300 THEN
        INSERT INTO market.kline_15m_dirty_ranges (
            instrument_id, dirty_start, changed_at, updated_at
        ) VALUES (
            NEW.instrument_id, NEW.open_time, NEW.effective_at, clock_timestamp()
        )
        ON CONFLICT (instrument_id) DO UPDATE SET
            dirty_start = LEAST(
                market.kline_15m_dirty_ranges.dirty_start,
                EXCLUDED.dirty_start
            ),
            changed_at = GREATEST(
                market.kline_15m_dirty_ranges.changed_at,
                EXCLUDED.changed_at
            ),
            updated_at = clock_timestamp();

        INSERT INTO market.kline_ema_dirty_ranges (
            instrument_id, interval_seconds, dirty_start, changed_at, updated_at
        )
        SELECT
            NEW.instrument_id,
            interval_seconds,
            NEW.open_time,
            NEW.effective_at,
            clock_timestamp()
        FROM unnest(ARRAY[300, 900, 3600]) AS intervals(interval_seconds)
        ON CONFLICT (instrument_id, interval_seconds) DO UPDATE SET
            dirty_start = LEAST(
                market.kline_ema_dirty_ranges.dirty_start,
                EXCLUDED.dirty_start
            ),
            changed_at = GREATEST(
                market.kline_ema_dirty_ranges.changed_at,
                EXCLUDED.changed_at
            ),
            updated_at = clock_timestamp();
    END IF;
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_mark_kline_15m_dirty_from_kline ON market.klines;
CREATE TRIGGER trg_mark_kline_15m_dirty_from_kline
AFTER INSERT OR UPDATE
ON market.klines
FOR EACH ROW EXECUTE FUNCTION market.mark_kline_15m_dirty_from_kline();

CREATE OR REPLACE FUNCTION market.mark_kline_15m_dirty_from_oi()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO market.kline_15m_dirty_ranges (
        instrument_id, dirty_start, changed_at, updated_at
    ) VALUES (
        NEW.instrument_id,
        date_bin('15 minutes', NEW.observed_at, TIMESTAMPTZ '1970-01-01'),
        NEW.collected_at,
        clock_timestamp()
    )
    ON CONFLICT (instrument_id) DO UPDATE SET
        dirty_start = LEAST(
            market.kline_15m_dirty_ranges.dirty_start,
            EXCLUDED.dirty_start
        ),
        changed_at = GREATEST(
            market.kline_15m_dirty_ranges.changed_at,
            EXCLUDED.changed_at
        ),
        updated_at = clock_timestamp();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_mark_kline_15m_dirty_from_oi
ON market.open_interest_observations;
CREATE TRIGGER trg_mark_kline_15m_dirty_from_oi
AFTER INSERT OR UPDATE
ON market.open_interest_observations
FOR EACH ROW EXECUTE FUNCTION market.mark_kline_15m_dirty_from_oi();

-- Existing checkpoints predate the trigger. Seed one bounded catch-up range per
-- instrument so deployment catches recent downtime without scanning compressed
-- history by change timestamp.
INSERT INTO market.kline_15m_dirty_ranges (
    instrument_id, dirty_start, changed_at
)
SELECT
    instrument_id,
    date_bin(
        '15 minutes',
        GREATEST(
            COALESCE(last_open_time, clock_timestamp() - INTERVAL '10 days'),
            clock_timestamp() - INTERVAL '10 days'
        ),
        TIMESTAMPTZ '1970-01-01'
    ),
    clock_timestamp()
FROM market.kline_15m_checkpoints
ON CONFLICT (instrument_id) DO UPDATE SET
    dirty_start = LEAST(
        market.kline_15m_dirty_ranges.dirty_start,
        EXCLUDED.dirty_start
    ),
    changed_at = GREATEST(
        market.kline_15m_dirty_ranges.changed_at,
        EXCLUDED.changed_at
    ),
    updated_at = clock_timestamp();

INSERT INTO market.kline_ema_dirty_ranges (
    instrument_id, interval_seconds, dirty_start, changed_at
)
SELECT
    instrument_id,
    interval_seconds,
    date_bin(
        make_interval(secs => interval_seconds),
        GREATEST(
            COALESCE(last_open_time, clock_timestamp() - INTERVAL '10 days'),
            clock_timestamp() - INTERVAL '10 days'
        ),
        TIMESTAMPTZ '1970-01-01'
    ),
    clock_timestamp()
FROM market.kline_ema_checkpoints
ON CONFLICT (instrument_id, interval_seconds) DO UPDATE SET
    dirty_start = LEAST(
        market.kline_ema_dirty_ranges.dirty_start,
        EXCLUDED.dirty_start
    ),
    changed_at = GREATEST(
        market.kline_ema_dirty_ranges.changed_at,
        EXCLUDED.changed_at
    ),
    updated_at = clock_timestamp();

GRANT SELECT, INSERT, UPDATE, DELETE ON market.kline_15m_dirty_ranges
TO tb2_collector;
GRANT SELECT, INSERT, UPDATE, DELETE ON market.kline_ema_dirty_ranges
TO tb2_collector;
GRANT SELECT ON market.kline_15m_dirty_ranges
TO tb2_trader, tb2_analysis_ro, tb2_backup;
GRANT SELECT ON market.kline_ema_dirty_ranges
TO tb2_trader, tb2_analysis_ro, tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '016_kline_15m_dirty_ranges',
    encode(
        digest('auto_trade_v2_016_indicator_dirty_ranges_v1', 'sha256'),
        'hex'
    ),
    'Track bounded 15m and EMA source changes outside compressed hypertables'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
