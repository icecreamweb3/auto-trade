\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

-- Candidate scans need the frozen reference dataset identity as well as the
-- approved configuration.  A fixed-baseline scan may rebuild candidate support
-- only when it is moving to a different immutable dataset; all normal scans
-- continue to consume the already frozen reference support.
CREATE OR REPLACE FUNCTION strategy_training.training_model_a_candidate_scan_random_context(
    p_task_id uuid, p_lease_token uuid
)
RETURNS TABLE (
    random_baseline_config_version_id uuid,
    config_json jsonb,
    reference_dataset_version_id uuid
)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training
AS $$
    SELECT config.random_baseline_config_version_id,
           config.config_json,
           reference_set.dataset_version_id
    FROM strategy_training.training_model_a_candidate_scan_random_config(
        p_task_id, p_lease_token
    ) config
    JOIN strategy_training.training_random_baseline_reference_sets reference_set
      ON reference_set.reference_set_id =
         (config.config_json ->> 'reference_set_id')::uuid
     AND reference_set.status = 'READY'
$$;

ALTER FUNCTION strategy_training.training_model_a_candidate_scan_random_context(uuid, uuid)
OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION
    strategy_training.training_model_a_candidate_scan_random_context(uuid, uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    strategy_training.training_model_a_candidate_scan_random_context(uuid, uuid)
TO tb2_training_rw;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '069_training_random_baseline_reference_rebuild',
    encode(public.digest(
        'auto_trade_v2_069_training_random_baseline_reference_rebuild_v1',
        'sha256'
    ), 'hex'),
    'Expose frozen reference dataset identity for governed fixed-baseline support rebuilds'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
