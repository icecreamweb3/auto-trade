\set ON_ERROR_STOP on
\pset pager off

BEGIN;

ALTER TABLE trade.paper_trades
    ADD COLUMN IF NOT EXISTS gross_pnl numeric(24, 8),
    ADD COLUMN IF NOT EXISTS entry_fee numeric(24, 8) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS exit_fee numeric(24, 8) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS fee numeric(24, 8) NOT NULL DEFAULT 0;

UPDATE trade.paper_trades
SET gross_pnl = realized_pnl
WHERE gross_pnl IS NULL;

ALTER TABLE trade.paper_trades
    ALTER COLUMN gross_pnl SET NOT NULL,
    ALTER COLUMN gross_pnl SET DEFAULT 0;

ALTER TABLE trade.paper_trades
    DROP CONSTRAINT IF EXISTS ck_paper_trades_nonnegative_fees;

ALTER TABLE trade.paper_trades
    ADD CONSTRAINT ck_paper_trades_nonnegative_fees
    CHECK (entry_fee >= 0 AND exit_fee >= 0 AND fee >= 0);

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '015_paper_trading_fees',
    encode(digest('auto_trade_v2_015_paper_trading_fees_v1', 'sha256'), 'hex'),
    'Record maker and taker fees for paper trades'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
