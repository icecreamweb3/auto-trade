BEGIN;

CREATE OR REPLACE FUNCTION strategy_training.finalize_training_random_baseline_coverage(
    p_task_id uuid, p_lease_token uuid
)
RETURNS text
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = pg_catalog, strategy_training, core, public
AS $$
DECLARE task_record strategy_training.training_tasks%ROWTYPE; config_record record;
        total_value integer; evaluable_value integer; excluded_value integer;
        days_value integer; valid_folds_value integer; coverage_value numeric;
        folds_value jsonb; distributions_value jsonb; status_value text; hash_value char(64);
BEGIN
    SELECT * INTO STRICT task_record FROM strategy_training.training_tasks WHERE task_id = p_task_id;
    IF task_record.state <> 'RUNNING' OR task_record.executor_kind <> 'EVALUATOR'
       OR task_record.task_type <> 'MODEL_A_EVALUATION'
       OR task_record.lease_token IS DISTINCT FROM p_lease_token
       OR task_record.lease_expires_at <= clock_timestamp() THEN
        RAISE EXCEPTION 'coverage finalization requires its active evaluator lease' USING ERRCODE = '40001';
    END IF;
    SELECT config.config_version_id, config.config_json INTO STRICT config_record
    FROM strategy_training.training_iterations iteration
    JOIN strategy_training.training_experiment_config_bindings binding
      ON binding.experiment_id = iteration.experiment_id AND binding.config_type = 'RANDOM_BASELINE'
    JOIN strategy_training.training_config_versions config ON config.config_version_id = binding.config_version_id
    WHERE iteration.iteration_id = task_record.iteration_id;
    WITH entries AS MATERIALIZED (
        SELECT entry.entry_event_id, entry.signal_time, entry.symbol,
               stratum.volatility_bucket, stratum.liquidity_bucket,
               baseline.matched_entry_event_id IS NOT NULL AS evaluable
        FROM strategy_training.training_entry_events entry
        JOIN strategy_training.training_random_baseline_signal_strata stratum USING (entry_event_id)
        LEFT JOIN strategy_training.training_random_entry_baselines baseline
          ON baseline.matched_entry_event_id = entry.entry_event_id
        LEFT JOIN strategy_training.training_random_baseline_frame_exclusions exclusion
          ON exclusion.entry_event_id = entry.entry_event_id
        WHERE entry.generating_iteration_id = task_record.iteration_id AND entry.status = 'COMPLETE'
          AND (baseline.matched_entry_event_id IS NOT NULL OR exclusion.entry_event_id IS NOT NULL)
    ), anchor AS (SELECT min(signal_time::date) AS first_day FROM entries), folded AS (
        SELECT floor((signal_time::date - first_day)::numeric /
                     (config_record.config_json ->> 'fold_duration_days')::integer)::integer AS fold_no,
               count(*)::integer AS total_count,
               count(*) FILTER (WHERE evaluable)::integer AS evaluable_count
        FROM entries CROSS JOIN anchor GROUP BY 1
    )
    SELECT count(*)::integer, count(*) FILTER (WHERE evaluable)::integer,
           count(*) FILTER (WHERE NOT evaluable)::integer,
           count(DISTINCT signal_time::date) FILTER (WHERE evaluable)::integer,
           COALESCE((SELECT count(*) FROM folded
             WHERE evaluable_count >= (config_record.config_json ->> 'minimum_evaluable_events_per_fold')::integer
               AND evaluable_count::numeric / total_count >=
                   (config_record.config_json ->> 'minimum_fold_coverage_ratio')::numeric), 0)::integer,
           COALESCE((SELECT jsonb_agg(jsonb_build_object(
               'fold_no', fold_no, 'total_count', total_count,
               'evaluable_count', evaluable_count,
               'coverage_ratio', evaluable_count::numeric / total_count,
               'valid', evaluable_count >= (config_record.config_json ->> 'minimum_evaluable_events_per_fold')::integer
                    AND evaluable_count::numeric / total_count >=
                        (config_record.config_json ->> 'minimum_fold_coverage_ratio')::numeric
             ) ORDER BY fold_no) FROM folded), '[]'::jsonb),
           jsonb_build_object(
             'by_date', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb) FROM (
                 SELECT signal_time::date::text AS key, jsonb_build_object(
                     'date', signal_time::date, 'evaluable', count(*) FILTER (WHERE evaluable),
                     'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data
                 FROM entries GROUP BY signal_time::date) grouped),
             'by_symbol', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb) FROM (
                 SELECT symbol AS key, jsonb_build_object('symbol', symbol,
                     'evaluable', count(*) FILTER (WHERE evaluable), 'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data
                 FROM entries GROUP BY symbol) grouped),
             'by_volatility_bucket', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb) FROM (
                 SELECT volatility_bucket AS key, jsonb_build_object('volatility_bucket', volatility_bucket,
                     'evaluable', count(*) FILTER (WHERE evaluable), 'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data
                 FROM entries GROUP BY volatility_bucket) grouped),
             'by_liquidity_bucket', (SELECT COALESCE(jsonb_agg(row_data ORDER BY key), '[]'::jsonb) FROM (
                 SELECT liquidity_bucket AS key, jsonb_build_object('liquidity_bucket', liquidity_bucket,
                     'evaluable', count(*) FILTER (WHERE evaluable), 'excluded', count(*) FILTER (WHERE NOT evaluable)) AS row_data
                 FROM entries GROUP BY liquidity_bucket) grouped)
           )
    INTO total_value, evaluable_value, excluded_value, days_value,
         valid_folds_value, folds_value, distributions_value FROM entries;
    IF total_value = 0 OR total_value <> (
        SELECT entry_event_count FROM strategy_training.training_iteration_entry_batches
        WHERE iteration_id = task_record.iteration_id
    ) THEN
        RAISE EXCEPTION 'coverage cannot finalize before every frozen entry is classified' USING ERRCODE = '55000';
    END IF;
    coverage_value := evaluable_value::numeric / total_value;
    status_value := CASE WHEN coverage_value >= (config_record.config_json ->> 'minimum_overall_coverage_ratio')::numeric
        AND days_value >= (config_record.config_json ->> 'minimum_effective_day_count')::integer
        AND valid_folds_value >= (config_record.config_json ->> 'minimum_valid_fold_count')::integer
        THEN 'READY' ELSE 'INSUFFICIENT_POWER' END;
    hash_value := encode(public.digest(jsonb_build_object(
        'distribution_comparison', distributions_value, 'effective_day_count', days_value,
        'evaluable_signal_count', evaluable_value, 'excluded_signal_count', excluded_value,
        'fold_metrics', folds_value, 'iteration_id', task_record.iteration_id,
        'overall_coverage_ratio', coverage_value, 'power_status', status_value,
        'reference_set_id', config_record.config_json ->> 'reference_set_id',
        'total_signal_count', total_value, 'valid_fold_count', valid_folds_value
    )::text, 'sha256'), 'hex');
    INSERT INTO strategy_training.training_random_baseline_coverage_reports (
        iteration_id, random_baseline_config_version_id, reference_set_id,
        total_signal_count, evaluable_signal_count, excluded_signal_count,
        overall_coverage_ratio, effective_day_count, valid_fold_count,
        power_status, fold_metrics, distribution_comparison, report_hash
    ) VALUES (
        task_record.iteration_id, config_record.config_version_id,
        (config_record.config_json ->> 'reference_set_id')::uuid,
        total_value, evaluable_value, excluded_value, coverage_value,
        days_value, valid_folds_value, status_value, folds_value,
        distributions_value, hash_value
    ) ON CONFLICT (iteration_id) DO NOTHING;
    RETURN status_value;
END
$$;

ALTER FUNCTION strategy_training.finalize_training_random_baseline_coverage(uuid, uuid)
OWNER TO tb2_training_owner;

REVOKE ALL ON FUNCTION strategy_training.finalize_training_random_baseline_coverage(uuid, uuid)
FROM PUBLIC;

GRANT EXECUTE ON FUNCTION strategy_training.finalize_training_random_baseline_coverage(uuid, uuid)
TO tb2_training_evaluator;

INSERT INTO core.schema_migrations(version, checksum_sha256, description)
VALUES (
    '072_training_random_baseline_coverage_grouping',
    encode(public.digest('auto_trade_v2_072_training_random_baseline_coverage_grouping_v1', 'sha256'), 'hex'),
    'Group random-baseline coverage date distributions by the underlying date expression'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
