\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- Migration 101 introduced immutable derived references.  A derived reference
-- intentionally reuses the fixed-baseline iteration of its root reference, so
-- uniqueness belongs to root rows rather than the complete lineage.
ALTER TABLE strategy_training.training_random_baseline_reference_sets
    DROP CONSTRAINT
        training_random_baseline_reference_s_reference_iteration_id_key;

CREATE UNIQUE INDEX ux_training_random_baseline_root_reference_iteration
ON strategy_training.training_random_baseline_reference_sets (reference_iteration_id)
WHERE source_reference_set_id IS NULL;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '102_training_random_baseline_reference_lineage',
    encode(public.digest(
        'auto_trade_v2_102_training_random_baseline_reference_lineage_v1',
        'sha256'
    ), 'hex'),
    'Allow one immutable complete-path reference derived from each root reference'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
