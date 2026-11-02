\set ON_ERROR_STOP on
\pset pager off

BEGIN;

DO $$
DECLARE
    source_constraint text;
    fold_constraint text;
BEGIN
    IF to_regclass('strategy_training.training_cross_fit_folds') IS NULL
       OR to_regclass('strategy_training.training_cross_fit_fold_searches') IS NULL
       OR to_regclass('strategy_training.training_go_no_go_evaluations') IS NULL
       OR to_regclass('strategy_training.training_go_no_go_fold_metrics') IS NULL THEN
        RAISE EXCEPTION 'D-stage Cross-fit tables are missing';
    END IF;
    SELECT pg_get_constraintdef(oid) INTO source_constraint
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_entry_events'::regclass
      AND conname = 'training_entry_events_source_use_check';
    IF source_constraint IS NULL OR position('CROSS_FIT_MODEL_A_CANDIDATE' IN source_constraint) = 0
       OR position('GO_NO_GO' IN source_constraint) = 0 THEN
        RAISE EXCEPTION 'temporary Cross-fit source/use guard is missing';
    END IF;
    SELECT pg_get_constraintdef(oid) INTO fold_constraint
    FROM pg_constraint
    WHERE conrelid = 'strategy_training.training_cross_fit_folds'::regclass
      AND conname = 'training_cross_fit_folds_inner_validation_count_check';
    IF fold_constraint IS NULL OR position('= 0' IN fold_constraint) = 0 THEN
        RAISE EXCEPTION 'Cross-fit folds must forbid inner validation';
    END IF;
END
$$;

ROLLBACK;
