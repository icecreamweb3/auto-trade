\set ON_ERROR_STOP on
\pset pager off

BEGIN;

CREATE TABLE IF NOT EXISTS market.telegram_channels (
    channel_id          bigint PRIMARY KEY,
    username            varchar(80) NOT NULL,
    title               text NOT NULL,
    history_complete    boolean NOT NULL DEFAULT false,
    earliest_message_id bigint,
    latest_message_id   bigint,
    last_history_at     timestamptz,
    last_realtime_at    timestamptz,
    created_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (username)
);

DROP TRIGGER IF EXISTS trg_telegram_channels_updated_at ON market.telegram_channels;
CREATE TRIGGER trg_telegram_channels_updated_at
BEFORE UPDATE ON market.telegram_channels
FOR EACH ROW EXECUTE FUNCTION core.set_updated_at();

CREATE TABLE IF NOT EXISTS market.telegram_messages (
    channel_id          bigint NOT NULL REFERENCES market.telegram_channels(channel_id),
    message_id          bigint NOT NULL,
    posted_at           timestamptz NOT NULL,
    edited_at           timestamptz,
    grouped_id          bigint,
    reply_to_message_id bigint,
    message_text        text NOT NULL DEFAULT '',
    media_type          varchar(80),
    raw_payload         jsonb NOT NULL,
    payload_hash        char(64) NOT NULL,
    collected_at        timestamptz NOT NULL,
    deleted_at          timestamptz,
    updated_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (channel_id, message_id)
);

CREATE INDEX IF NOT EXISTS ix_telegram_messages_posted
ON market.telegram_messages (channel_id, posted_at DESC, message_id DESC);

CREATE TABLE IF NOT EXISTS market.telegram_message_revisions (
    channel_id          bigint NOT NULL,
    message_id          bigint NOT NULL,
    payload_hash        char(64) NOT NULL,
    posted_at           timestamptz NOT NULL,
    edited_at           timestamptz,
    message_text        text NOT NULL DEFAULT '',
    raw_payload         jsonb NOT NULL,
    collected_at        timestamptz NOT NULL,
    PRIMARY KEY (channel_id, message_id, payload_hash),
    FOREIGN KEY (channel_id, message_id)
        REFERENCES market.telegram_messages(channel_id, message_id)
        DEFERRABLE INITIALLY DEFERRED
);

CREATE TABLE IF NOT EXISTS market.telegram_signals (
    channel_id          bigint NOT NULL,
    message_id          bigint NOT NULL,
    parser_version      varchar(32) NOT NULL,
    symbol_raw          varchar(80),
    symbol              varchar(32),
    signal_kind         varchar(32) NOT NULL CHECK (signal_kind IN (
        'ENTRY', 'CONTINUATION', 'REVERSAL_WARNING', 'INVALIDATION',
        'VOLATILITY_WAKE', 'EXIT', 'UNKNOWN'
    )),
    direction           varchar(16) NOT NULL CHECK (direction IN ('LONG', 'SHORT', 'NEUTRAL')),
    score               integer CHECK (score BETWEEN 0 AND 100),
    action_text         text,
    metrics             jsonb NOT NULL DEFAULT '{}'::jsonb,
    is_actionable       boolean NOT NULL DEFAULT false,
    parsed_at           timestamptz NOT NULL,
    PRIMARY KEY (channel_id, message_id, parser_version),
    FOREIGN KEY (channel_id, message_id)
        REFERENCES market.telegram_messages(channel_id, message_id)
        ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS ix_telegram_signals_time
ON market.telegram_signals (signal_kind, direction, parsed_at DESC);

GRANT SELECT, INSERT, UPDATE ON market.telegram_channels,
    market.telegram_messages, market.telegram_message_revisions,
    market.telegram_signals TO tb2_collector;
GRANT SELECT ON market.telegram_channels, market.telegram_messages,
    market.telegram_message_revisions, market.telegram_signals
    TO tb2_trader, tb2_analysis_ro, tb2_backup;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '018_telegram_channel_messages',
    encode(digest('auto_trade_v2_018_telegram_channel_messages_v1', 'sha256'), 'hex'),
    'Persist Telegram channel history, revisions and normalized external signals'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
