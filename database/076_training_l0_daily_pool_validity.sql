\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

DO $do$
DECLARE
    function_definition text;
    revised_definition text;
    old_fragment constant text := $fragment$
          AND evaluation.evaluation_at <= signal.open_time
        ORDER BY evaluation.evaluation_at DESC LIMIT 1
$fragment$;
    new_fragment constant text := $fragment$
          AND evaluation.evaluation_at <= signal.open_time
          AND signal.open_time < evaluation.evaluation_at + interval '1 day'
        ORDER BY evaluation.evaluation_at DESC LIMIT 1
$fragment$;
BEGIN
    function_definition := pg_get_functiondef(
        'strategy_training.build_training_opportunity_universe(uuid,uuid)'::regprocedure
    );
    IF strpos(function_definition, new_fragment) <> 0 THEN
        RAISE EXCEPTION 'L0 daily pool-validity guard already exists without migration record';
    END IF;
    IF strpos(function_definition, old_fragment) = 0 THEN
        RAISE EXCEPTION 'L0 pool lookup does not match the reviewed pre-076 definition';
    END IF;
    revised_definition := replace(function_definition, old_fragment, new_fragment);
    IF revised_definition = function_definition THEN
        RAISE EXCEPTION 'L0 daily pool-validity replacement made no change';
    END IF;
    EXECUTE revised_definition;
END
$do$;

ALTER FUNCTION strategy_training.build_training_opportunity_universe(uuid, uuid)
OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION
    strategy_training.build_training_opportunity_universe(uuid, uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION
    strategy_training.build_training_opportunity_universe(uuid, uuid)
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '076_training_l0_daily_pool_validity',
    encode(public.digest(
        'auto_trade_v2_076_training_l0_daily_pool_validity_v1', 'sha256'
    ), 'hex'),
    'Expire each historical daily pool evaluation after one UTC day in L0'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
