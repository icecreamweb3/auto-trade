\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

DO $do$
DECLARE
    function_definition text;
BEGIN
    function_definition := pg_get_functiondef(
        'strategy_training.create_training_candidate_entry_event(uuid,uuid,character,uuid,uuid,bigint,text,timestamp with time zone,timestamp with time zone,text,numeric,numeric,numeric,numeric,uuid,uuid,uuid,uuid,character)'::regprocedure
    );
    IF strpos(
        function_definition,
        'strategy_training.training_model_a_candidate_scan_entry_source'
    ) = 0 THEN
        IF strpos(function_definition, $$'IN_SAMPLE_MODEL_A'$$) = 0
           OR strpos(function_definition, $$'MODEL_A_DISCOVERY'$$) = 0 THEN
            RAISE EXCEPTION 'candidate-entry source projection is not recognized';
        END IF;
        function_definition := replace(
            function_definition,
            $$'IN_SAMPLE_MODEL_A'$$,
            $$strategy_training.training_model_a_candidate_scan_entry_source(p_task_id, p_lease_token)$$
        );
        function_definition := replace(
            function_definition,
            $$'MODEL_A_DISCOVERY'$$,
            $$CASE strategy_training.training_model_a_candidate_scan_entry_source(p_task_id, p_lease_token) WHEN 'FIXED_BASELINE_MODEL_A' THEN 'MODEL_B_PROTOTYPE' ELSE 'MODEL_A_DISCOVERY' END$$
        );
        EXECUTE function_definition;
    END IF;
END
$do$;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '064_training_candidate_entry_source',
    encode(digest(
        'auto_trade_v2_064_training_candidate_entry_source_v1',
        'sha256'
    ), 'hex'),
    'Resolve candidate entry source and use from the lease-bound iteration'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
