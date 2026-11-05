\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

DO $do$
DECLARE
    function_definition text;
BEGIN
    function_definition := pg_get_functiondef(
        'strategy_training.training_model_a_candidate_scan_bars(uuid,uuid,bigint)'::regprocedure
    );
    IF strpos(function_definition, 'rules.price_precision::integer') = 0 THEN
        IF strpos(function_definition, 'rules.price_precision,') = 0 THEN
            RAISE EXCEPTION 'candidate-scan price-precision projection is not recognized';
        END IF;
        function_definition := replace(
            function_definition,
            'rules.price_precision,',
            'rules.price_precision::integer,'
        );
        EXECUTE function_definition;
    END IF;
END
$do$;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '063_training_candidate_scan_result_types',
    encode(digest(
        'auto_trade_v2_063_training_candidate_scan_result_types_v1',
        'sha256'
    ), 'hex'),
    'Keep static-pruned candidate-scan result types equal to the public contract'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
