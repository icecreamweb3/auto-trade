\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE OR REPLACE FUNCTION strategy_training.guard_training_random_baseline_binding_v012()
RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog, strategy_training
AS $$
BEGIN
    IF NEW.config_type = 'RANDOM_BASELINE' AND NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_config_versions config
        JOIN strategy_training.training_random_baseline_reference_sets reference_set
          ON reference_set.reference_set_id =
             (config.config_json ->> 'reference_set_id')::uuid
         AND reference_set.status = 'READY'
        WHERE config.config_version_id = NEW.config_version_id
          AND config.config_type = 'RANDOM_BASELINE'
          AND config.semver::text NOT IN ('0.1.0', '0.1.1')
          AND config.status = 'READY'
    ) THEN
        RAISE EXCEPTION 'RANDOM_BASELINE 0.1.0/0.1.1 are audit-only; execution requires an approved-reference version'
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$$;

ALTER FUNCTION strategy_training.guard_training_random_baseline_binding_v012()
OWNER TO tb2_training_owner;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '068_training_random_baseline_binding_progression',
    encode(public.digest(
        'auto_trade_v2_068_training_random_baseline_binding_progression_v1',
        'sha256'
    ), 'hex'),
    'Allow experiment binding to new immutable random-baseline reference versions'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
