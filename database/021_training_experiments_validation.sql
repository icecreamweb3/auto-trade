\set ON_ERROR_STOP on
\pset pager off

BEGIN;

SELECT pg_advisory_xact_lock(hashtextextended('auto_trade_training_migrations', 0));

CREATE TABLE strategy_training.training_experiments (
    experiment_id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_mode                  varchar(24) NOT NULL
                                     CHECK (experiment_mode IN (
                                         'DISCOVERY', 'EXIT_POLICY', 'END_TO_END'
                                     )),
    parent_experiment_id              uuid
                                     REFERENCES strategy_training.training_experiments,
    dataset_version_id                uuid NOT NULL
                                     REFERENCES strategy_training.training_dataset_versions,
    resource_limit_config_version_id  uuid NOT NULL
                                     REFERENCES strategy_training.training_config_versions,
    experiment_name                   text NOT NULL,
    state                             varchar(16) NOT NULL DEFAULT 'DRAFT'
                                     CHECK (state IN (
                                         'DRAFT', 'RUNNING', 'PAUSED', 'STOPPED'
                                     )),
    stop_reason                       text,
    exposure_identity_hash            char(64) NOT NULL,
    created_by_user_id                uuid NOT NULL REFERENCES core.app_users(user_id),
    created_at                        timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at                        timestamptz,
    paused_at                         timestamptz,
    stopped_at                        timestamptz,
    CHECK (parent_experiment_id IS NULL OR parent_experiment_id <> experiment_id),
    CHECK (btrim(experiment_name) <> ''),
    CHECK (exposure_identity_hash ~ '^[0-9a-f]{64}$'),
    CHECK (
        (state = 'DRAFT' AND started_at IS NULL AND paused_at IS NULL
                         AND stopped_at IS NULL AND stop_reason IS NULL)
        OR (state = 'RUNNING' AND started_at IS NOT NULL AND stopped_at IS NULL
                           AND stop_reason IS NULL)
        OR (state = 'PAUSED' AND started_at IS NOT NULL AND paused_at IS NOT NULL
                          AND stopped_at IS NULL AND stop_reason IS NULL)
        OR (state = 'STOPPED' AND started_at IS NOT NULL AND stopped_at IS NOT NULL
                           AND stop_reason IS NOT NULL AND btrim(stop_reason) <> '')
    )
);

CREATE INDEX ix_training_experiments_state
ON strategy_training.training_experiments (state, created_at DESC);

CREATE TABLE strategy_training.training_experiment_config_bindings (
    experiment_id      uuid NOT NULL REFERENCES strategy_training.training_experiments,
    config_type        varchar(64) NOT NULL,
    config_version_id  uuid NOT NULL
                       REFERENCES strategy_training.training_config_versions,
    bound_at           timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (experiment_id, config_type),
    UNIQUE (experiment_id, config_version_id)
);

CREATE TABLE strategy_training.training_iterations (
    iteration_id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id            uuid NOT NULL REFERENCES strategy_training.training_experiments,
    candidate_version        integer NOT NULL CHECK (candidate_version > 0),
    parent_iteration_id      uuid REFERENCES strategy_training.training_iterations,
    candidate_source         varchar(24) NOT NULL
                             CHECK (candidate_source IN (
                                 'FIXED_BASELINE', 'OPTUNA_TPE', 'RANDOM_SEARCH',
                                 'LLM_ADVICE', 'MANUAL_APPROVED'
                             )),
    random_seed              bigint NOT NULL,
    candidate_parameters     jsonb NOT NULL,
    candidate_content_hash   char(64) NOT NULL,
    resource_budget          jsonb NOT NULL,
    state                    varchar(16) NOT NULL DEFAULT 'CREATED'
                             CHECK (state IN (
                                 'CREATED', 'VALIDATING', 'RUNNING', 'SUCCEEDED',
                                 'FAILED', 'REJECTED', 'CANCELLED'
                             )),
    rejection_code           varchar(64),
    failure_detail_hash      char(64),
    retry_of_iteration_id    uuid REFERENCES strategy_training.training_iterations,
    created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
    validation_started_at    timestamptz,
    run_started_at           timestamptz,
    completed_at             timestamptz,
    CHECK (parent_iteration_id IS NULL OR parent_iteration_id <> iteration_id),
    CHECK (retry_of_iteration_id IS NULL OR retry_of_iteration_id <> iteration_id),
    CHECK (jsonb_typeof(candidate_parameters) = 'object'),
    CHECK (candidate_parameters <> '{}'::jsonb),
    CHECK (candidate_content_hash ~ '^[0-9a-f]{64}$'),
    CHECK (
        candidate_content_hash = encode(digest(candidate_parameters::text, 'sha256'), 'hex')
    ),
    CHECK (jsonb_typeof(resource_budget) = 'object'),
    CHECK (resource_budget <> '{}'::jsonb),
    CHECK (failure_detail_hash IS NULL OR failure_detail_hash ~ '^[0-9a-f]{64}$'),
    CHECK (
        (state = 'CREATED' AND validation_started_at IS NULL
                           AND run_started_at IS NULL AND completed_at IS NULL
                           AND rejection_code IS NULL)
        OR (state = 'VALIDATING' AND validation_started_at IS NOT NULL
                              AND run_started_at IS NULL AND completed_at IS NULL
                              AND rejection_code IS NULL)
        OR (state = 'RUNNING' AND validation_started_at IS NOT NULL
                           AND run_started_at IS NOT NULL AND completed_at IS NULL
                           AND rejection_code IS NULL)
        OR (state = 'SUCCEEDED' AND validation_started_at IS NOT NULL
                             AND run_started_at IS NOT NULL AND completed_at IS NOT NULL
                             AND rejection_code IS NULL)
        OR (state = 'FAILED' AND validation_started_at IS NOT NULL
                          AND completed_at IS NOT NULL AND rejection_code IS NOT NULL
                          AND btrim(rejection_code) <> '')
        OR (state = 'REJECTED' AND validation_started_at IS NOT NULL
                            AND run_started_at IS NULL AND completed_at IS NOT NULL
                            AND rejection_code IS NOT NULL AND btrim(rejection_code) <> '')
        OR (state = 'CANCELLED' AND completed_at IS NOT NULL
                             AND rejection_code IS NOT NULL AND btrim(rejection_code) <> '')
    ),
    UNIQUE (experiment_id, candidate_version),
    UNIQUE (experiment_id, candidate_content_hash)
);

CREATE INDEX ix_training_iterations_experiment_state
ON strategy_training.training_iterations (experiment_id, state, candidate_version);

CREATE TABLE strategy_training.training_optimizer_runs (
    optimizer_run_id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id                   uuid NOT NULL REFERENCES strategy_training.training_experiments,
    optimizer_kind                  varchar(16) NOT NULL
                                    CHECK (optimizer_kind IN ('TPE', 'RANDOM')),
    search_space_config_version_id  uuid NOT NULL
                                    REFERENCES strategy_training.training_config_versions,
    trial_budget                    integer NOT NULL CHECK (trial_budget > 0),
    random_seed                     bigint NOT NULL,
    worker_identity                 text NOT NULL,
    state                           varchar(16) NOT NULL DEFAULT 'CREATED'
                                    CHECK (state IN (
                                        'CREATED', 'RUNNING', 'PAUSED', 'SUCCEEDED',
                                        'FAILED', 'CANCELLED'
                                    )),
    failure_code                    varchar(64),
    created_at                      timestamptz NOT NULL DEFAULT clock_timestamp(),
    started_at                      timestamptz,
    ended_at                        timestamptz,
    CHECK (btrim(worker_identity) <> ''),
    CHECK (
        (state = 'CREATED' AND started_at IS NULL AND ended_at IS NULL
                           AND failure_code IS NULL)
        OR (state IN ('RUNNING', 'PAUSED') AND started_at IS NOT NULL
                                           AND ended_at IS NULL
                                           AND failure_code IS NULL)
        OR (state = 'SUCCEEDED' AND started_at IS NOT NULL AND ended_at IS NOT NULL
                             AND failure_code IS NULL)
        OR (state IN ('FAILED', 'CANCELLED') AND ended_at IS NOT NULL
                                              AND failure_code IS NOT NULL
                                              AND btrim(failure_code) <> '')
    )
);

CREATE TABLE strategy_training.training_optimizer_checkpoints (
    optimizer_checkpoint_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    optimizer_run_id         uuid NOT NULL REFERENCES strategy_training.training_optimizer_runs,
    trial_number             integer NOT NULL CHECK (trial_number >= 0),
    study_state_hash         char(64) NOT NULL CHECK (study_state_hash ~ '^[0-9a-f]{64}$'),
    checkpoint_uri_hash      char(64) NOT NULL CHECK (checkpoint_uri_hash ~ '^[0-9a-f]{64}$'),
    completed_trial_count    integer NOT NULL CHECK (completed_trial_count >= 0),
    failed_trial_count       integer NOT NULL CHECK (failed_trial_count >= 0),
    created_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (optimizer_run_id, trial_number),
    UNIQUE (optimizer_run_id, study_state_hash)
);

CREATE TABLE strategy_training.training_final_candidate_freezes (
    final_candidate_freeze_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    experiment_id              uuid NOT NULL UNIQUE
                               REFERENCES strategy_training.training_experiments,
    iteration_id               uuid NOT NULL UNIQUE
                               REFERENCES strategy_training.training_iterations,
    candidate_content_hash     char(64) NOT NULL
                               CHECK (candidate_content_hash ~ '^[0-9a-f]{64}$'),
    freeze_manifest_hash       char(64) NOT NULL
                               CHECK (freeze_manifest_hash ~ '^[0-9a-f]{64}$'),
    frozen_by_user_id          uuid NOT NULL REFERENCES core.app_users(user_id),
    frozen_at                  timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE OR REPLACE FUNCTION strategy_training.compute_validation_scope_hash(
    p_partition_start_at timestamptz,
    p_partition_end_at timestamptz,
    p_ticker_pool_rule_version_id uuid
)
RETURNS char(64)
LANGUAGE sql
IMMUTABLE
STRICT
AS $$
    SELECT encode(
        public.digest(
            concat_ws(
                '|',
                to_char(p_partition_start_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
                to_char(p_partition_end_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US'),
                p_ticker_pool_rule_version_id::text
            ),
            'sha256'
        ),
        'hex'
    )::char(64)
$$;

CREATE TABLE strategy_training.training_validation_scopes (
    validation_scope_id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    scope_hash                          char(64) NOT NULL UNIQUE,
    partition_start_at                  timestamptz NOT NULL,
    partition_end_at                    timestamptz NOT NULL,
    ticker_pool_rule_version_id         uuid NOT NULL
                                        REFERENCES strategy_training.training_config_versions,
    validation_protocol_version_id      uuid NOT NULL
                                        REFERENCES strategy_training.training_config_versions,
    max_evaluation_count                integer NOT NULL CHECK (max_evaluation_count > 0),
    alpha_total                         numeric(18, 12) NOT NULL
                                        CHECK (alpha_total > 0 AND alpha_total < 1),
    model_a_max_evaluation_count        integer NOT NULL
                                        CHECK (model_a_max_evaluation_count >= 0),
    model_a_alpha_total                 numeric(18, 12) NOT NULL
                                        CHECK (model_a_alpha_total >= 0),
    model_b_max_evaluation_count        integer NOT NULL
                                        CHECK (model_b_max_evaluation_count >= 0),
    model_b_alpha_total                 numeric(18, 12) NOT NULL
                                        CHECK (model_b_alpha_total >= 0),
    reserved_evaluation_count           integer NOT NULL DEFAULT 0
                                        CHECK (reserved_evaluation_count >= 0),
    reserved_alpha                      numeric(18, 12) NOT NULL DEFAULT 0
                                        CHECK (reserved_alpha >= 0),
    model_a_reserved_evaluation_count   integer NOT NULL DEFAULT 0
                                        CHECK (model_a_reserved_evaluation_count >= 0),
    model_a_reserved_alpha              numeric(18, 12) NOT NULL DEFAULT 0
                                        CHECK (model_a_reserved_alpha >= 0),
    model_b_reserved_evaluation_count   integer NOT NULL DEFAULT 0
                                        CHECK (model_b_reserved_evaluation_count >= 0),
    model_b_reserved_alpha              numeric(18, 12) NOT NULL DEFAULT 0
                                        CHECK (model_b_reserved_alpha >= 0),
    state                               varchar(16) NOT NULL DEFAULT 'OPEN'
                                        CHECK (state IN ('OPEN', 'EXHAUSTED', 'CLOSED')),
    created_by_user_id                  uuid NOT NULL REFERENCES core.app_users(user_id),
    created_at                          timestamptz NOT NULL DEFAULT clock_timestamp(),
    closed_at                           timestamptz,
    CHECK (partition_start_at < partition_end_at),
    CHECK (
        scope_hash = strategy_training.compute_validation_scope_hash(
            partition_start_at, partition_end_at, ticker_pool_rule_version_id
        )
    ),
    CHECK (
        model_a_max_evaluation_count + model_b_max_evaluation_count
        <= max_evaluation_count
    ),
    CHECK (model_a_alpha_total + model_b_alpha_total <= alpha_total),
    CHECK (reserved_evaluation_count <= max_evaluation_count),
    CHECK (reserved_alpha <= alpha_total),
    CHECK (model_a_reserved_evaluation_count <= model_a_max_evaluation_count),
    CHECK (model_a_reserved_alpha <= model_a_alpha_total),
    CHECK (model_b_reserved_evaluation_count <= model_b_max_evaluation_count),
    CHECK (model_b_reserved_alpha <= model_b_alpha_total),
    CHECK (
        reserved_evaluation_count =
            model_a_reserved_evaluation_count + model_b_reserved_evaluation_count
    ),
    CHECK (reserved_alpha = model_a_reserved_alpha + model_b_reserved_alpha),
    CHECK (
        (state = 'CLOSED' AND closed_at IS NOT NULL)
        OR (state <> 'CLOSED' AND closed_at IS NULL)
    )
);

CREATE TABLE strategy_training.training_validation_reservations (
    validation_reservation_id  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    validation_scope_id        uuid NOT NULL
                               REFERENCES strategy_training.training_validation_scopes,
    final_candidate_freeze_id  uuid NOT NULL UNIQUE
                               REFERENCES strategy_training.training_final_candidate_freezes,
    model_family               varchar(8) NOT NULL
                               CHECK (model_family IN ('MODEL_A', 'MODEL_B')),
    evaluation_count           integer NOT NULL CHECK (evaluation_count > 0),
    alpha_reserved             numeric(18, 12) NOT NULL
                               CHECK (alpha_reserved > 0 AND alpha_reserved < 1),
    reservation_request_id     uuid NOT NULL UNIQUE,
    reserved_by_user_id        uuid NOT NULL REFERENCES core.app_users(user_id),
    reserved_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (validation_scope_id, final_candidate_freeze_id)
);

CREATE INDEX ix_training_validation_reservations_scope
ON strategy_training.training_validation_reservations (validation_scope_id, reserved_at);

CREATE TABLE strategy_training.training_validation_evaluations (
    validation_evaluation_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    validation_reservation_id  uuid NOT NULL UNIQUE
                               REFERENCES strategy_training.training_validation_reservations,
    validation_scope_id        uuid NOT NULL
                               REFERENCES strategy_training.training_validation_scopes,
    experiment_id              uuid NOT NULL REFERENCES strategy_training.training_experiments,
    final_candidate_freeze_id  uuid NOT NULL UNIQUE
                               REFERENCES strategy_training.training_final_candidate_freezes,
    evaluation_attempt         integer NOT NULL DEFAULT 1 CHECK (evaluation_attempt = 1),
    alpha_used                 numeric(18, 12) NOT NULL
                               CHECK (alpha_used > 0 AND alpha_used < 1),
    confidence_interval        jsonb NOT NULL,
    correction_result         jsonb NOT NULL,
    result_hash                char(64) NOT NULL CHECK (result_hash ~ '^[0-9a-f]{64}$'),
    evaluated_at               timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (jsonb_typeof(confidence_interval) = 'object'),
    CHECK (confidence_interval <> '{}'::jsonb),
    CHECK (jsonb_typeof(correction_result) = 'object'),
    CHECK (correction_result <> '{}'::jsonb)
);

CREATE TABLE strategy_training.training_iteration_metrics (
    iteration_metric_id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    iteration_id                     uuid NOT NULL REFERENCES strategy_training.training_iterations,
    partition                        varchar(16) NOT NULL
                                     CHECK (partition IN ('TRAIN', 'VALIDATION')),
    validation_evaluation_id         uuid
                                     REFERENCES strategy_training.training_validation_evaluations,
    metric_name                      varchar(96) NOT NULL,
    metric_value                     numeric NOT NULL,
    sample_count                     bigint NOT NULL CHECK (sample_count >= 0),
    effective_independent_day_count  numeric(12, 4) NOT NULL
                                     CHECK (effective_independent_day_count >= 0),
    calculation_version              text NOT NULL,
    evidence_hash                    char(64) NOT NULL CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    created_at                       timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(metric_name) <> ''),
    CHECK (btrim(calculation_version) <> ''),
    CHECK (
        (partition = 'TRAIN' AND validation_evaluation_id IS NULL)
        OR (partition = 'VALIDATION' AND validation_evaluation_id IS NOT NULL)
    ),
    UNIQUE NULLS NOT DISTINCT (
        iteration_id, partition, validation_evaluation_id, metric_name, calculation_version
    )
);

CREATE INDEX ix_training_iteration_metrics_iteration
ON strategy_training.training_iteration_metrics (iteration_id, partition, metric_name);

CREATE TABLE strategy_training.training_score_components (
    score_component_id        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    iteration_id              uuid NOT NULL REFERENCES strategy_training.training_iterations,
    scoring_config_version_id uuid NOT NULL
                              REFERENCES strategy_training.training_config_versions,
    score_family              varchar(16) NOT NULL
                              CHECK (score_family IN ('DISCOVERY', 'EXIT_POLICY', 'END_TO_END')),
    component_name            varchar(96) NOT NULL,
    component_value           numeric NOT NULL,
    component_weight          numeric NOT NULL,
    hard_gate_passed          boolean NOT NULL,
    hard_gate_reason          text,
    final_score               numeric,
    evidence_hash             char(64) NOT NULL CHECK (evidence_hash ~ '^[0-9a-f]{64}$'),
    created_at                timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (btrim(component_name) <> ''),
    CHECK (
        (hard_gate_passed AND hard_gate_reason IS NULL)
        OR (NOT hard_gate_passed AND hard_gate_reason IS NOT NULL
            AND btrim(hard_gate_reason) <> '' AND final_score IS NULL)
    ),
    UNIQUE (iteration_id, scoring_config_version_id, component_name)
);

CREATE TABLE strategy_training.training_state_transition_log (
    transition_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    object_type         varchar(32) NOT NULL
                        CHECK (object_type IN (
                            'EXPERIMENT', 'ITERATION', 'OPTIMIZER_RUN',
                            'VALIDATION_SCOPE', 'CONFIG', 'DATASET', 'MODEL', 'PROMOTION'
                        )),
    object_id           uuid NOT NULL,
    old_state           varchar(32),
    new_state           varchar(32) NOT NULL,
    actor_user_id       uuid REFERENCES core.app_users(user_id),
    actor_service       text,
    reason              text NOT NULL,
    request_id          uuid NOT NULL,
    occurred_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    CHECK (old_state IS NULL OR btrim(old_state) <> ''),
    CHECK (btrim(new_state) <> ''),
    CHECK (btrim(reason) <> ''),
    CHECK (
        (actor_user_id IS NOT NULL AND actor_service IS NULL)
        OR (actor_user_id IS NULL AND actor_service IS NOT NULL
            AND btrim(actor_service) <> '')
    )
);

CREATE INDEX ix_training_state_transition_object
ON strategy_training.training_state_transition_log (object_type, object_id, occurred_at);

CREATE OR REPLACE FUNCTION strategy_training.guard_experiment_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    dataset_record strategy_training.training_dataset_versions%ROWTYPE;
    resource_record strategy_training.training_config_versions%ROWTYPE;
BEGIN
    SELECT * INTO dataset_record
    FROM strategy_training.training_dataset_versions
    WHERE dataset_version_id = NEW.dataset_version_id;

    IF dataset_record.status <> 'READY' OR dataset_record.partition <> 'TRAIN' THEN
        RAISE EXCEPTION 'experiments require a READY TRAIN dataset'
            USING ERRCODE = '23514';
    END IF;

    SELECT * INTO resource_record
    FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.resource_limit_config_version_id;

    IF resource_record.config_type <> 'RESOURCE_LIMITS' OR resource_record.status <> 'READY' THEN
        RAISE EXCEPTION 'experiments require a READY RESOURCE_LIMITS config'
            USING ERRCODE = '23514';
    END IF;

    IF NEW.parent_experiment_id IS NOT NULL AND NOT EXISTS (
        SELECT 1
        FROM strategy_training.training_experiments parent
        WHERE parent.experiment_id = NEW.parent_experiment_id
          AND parent.dataset_version_id = NEW.dataset_version_id
    ) THEN
        RAISE EXCEPTION 'parent experiment must use the same dataset version'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_experiment_config_binding_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    experiment_state text;
    config_record strategy_training.training_config_versions%ROWTYPE;
BEGIN
    SELECT state INTO experiment_state
    FROM strategy_training.training_experiments
    WHERE experiment_id = NEW.experiment_id
    FOR UPDATE;

    IF experiment_state <> 'DRAFT' THEN
        RAISE EXCEPTION 'experiment configs can only be bound while DRAFT'
            USING ERRCODE = '55000';
    END IF;

    SELECT * INTO config_record
    FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.config_version_id;

    IF config_record.status <> 'READY' OR config_record.config_type <> NEW.config_type THEN
        RAISE EXCEPTION 'experiment config binding requires matching READY config type'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_iteration_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    experiment_record strategy_training.training_experiments%ROWTYPE;
BEGIN
    SELECT * INTO experiment_record
    FROM strategy_training.training_experiments
    WHERE experiment_id = NEW.experiment_id
    FOR UPDATE;

    IF experiment_record.experiment_mode = 'END_TO_END' THEN
        RAISE EXCEPTION 'END_TO_END experiments cannot create search iterations'
            USING ERRCODE = '23514';
    END IF;

    IF experiment_record.state <> 'RUNNING' THEN
        RAISE EXCEPTION 'iterations require a RUNNING experiment'
            USING ERRCODE = '55000';
    END IF;

    IF NEW.parent_iteration_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM strategy_training.training_iterations parent
        WHERE parent.iteration_id = NEW.parent_iteration_id
          AND parent.experiment_id = NEW.experiment_id
    ) THEN
        RAISE EXCEPTION 'parent iteration must belong to the same experiment'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_optimizer_run_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    experiment_record strategy_training.training_experiments%ROWTYPE;
    config_record strategy_training.training_config_versions%ROWTYPE;
BEGIN
    SELECT * INTO experiment_record
    FROM strategy_training.training_experiments
    WHERE experiment_id = NEW.experiment_id;

    IF experiment_record.experiment_mode = 'END_TO_END' THEN
        RAISE EXCEPTION 'END_TO_END experiments cannot start optimizer runs'
            USING ERRCODE = '23514';
    END IF;

    IF experiment_record.state <> 'RUNNING' THEN
        RAISE EXCEPTION 'optimizer runs require a RUNNING experiment'
            USING ERRCODE = '55000';
    END IF;

    SELECT * INTO config_record
    FROM strategy_training.training_config_versions
    WHERE config_version_id = NEW.search_space_config_version_id;

    IF config_record.config_type <> 'SEARCH_SPACE' OR config_record.status <> 'READY' THEN
        RAISE EXCEPTION 'optimizer runs require a READY SEARCH_SPACE config'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_final_candidate_freeze_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    iteration_record strategy_training.training_iterations%ROWTYPE;
    experiment_state text;
BEGIN
    SELECT * INTO iteration_record
    FROM strategy_training.training_iterations
    WHERE iteration_id = NEW.iteration_id
    FOR UPDATE;

    IF iteration_record.experiment_id <> NEW.experiment_id
       OR iteration_record.state <> 'SUCCEEDED'
       OR iteration_record.candidate_content_hash <> NEW.candidate_content_hash THEN
        RAISE EXCEPTION 'frozen candidate must be a matching SUCCEEDED TRAIN iteration'
            USING ERRCODE = '23514';
    END IF;

    SELECT state INTO experiment_state
    FROM strategy_training.training_experiments
    WHERE experiment_id = NEW.experiment_id;

    IF experiment_state <> 'STOPPED' THEN
        RAISE EXCEPTION 'candidate can only freeze after TRAIN experiment is STOPPED'
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_validation_scope_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_config_versions config
        WHERE config.config_version_id = NEW.ticker_pool_rule_version_id
          AND config.config_type = 'TICKER_POOL_RULES'
          AND config.status = 'READY'
    ) THEN
        RAISE EXCEPTION 'validation scope requires READY TICKER_POOL_RULES'
            USING ERRCODE = '23514';
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM strategy_training.training_config_versions config
        WHERE config.config_version_id = NEW.validation_protocol_version_id
          AND config.config_type = 'VALIDATION_PROTOCOL'
          AND config.status = 'READY'
    ) THEN
        RAISE EXCEPTION 'validation scope requires READY VALIDATION_PROTOCOL'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_validation_reservation_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    scope_record strategy_training.training_validation_scopes%ROWTYPE;
BEGIN
    IF NEW.evaluation_count <> 1 THEN
        RAISE EXCEPTION 'each frozen candidate has exactly one validation evaluation'
            USING ERRCODE = '23514';
    END IF;

    SELECT * INTO scope_record
    FROM strategy_training.training_validation_scopes
    WHERE validation_scope_id = NEW.validation_scope_id
    FOR UPDATE;

    IF scope_record.state <> 'OPEN' THEN
        RAISE EXCEPTION 'validation scope is not OPEN' USING ERRCODE = '55000';
    END IF;

    IF scope_record.reserved_evaluation_count + NEW.evaluation_count
       > scope_record.max_evaluation_count
       OR scope_record.reserved_alpha + NEW.alpha_reserved > scope_record.alpha_total THEN
        RAISE EXCEPTION 'validation global budget exhausted' USING ERRCODE = '54000';
    END IF;

    IF NEW.model_family = 'MODEL_A' AND (
        scope_record.model_a_reserved_evaluation_count + NEW.evaluation_count
            > scope_record.model_a_max_evaluation_count
        OR scope_record.model_a_reserved_alpha + NEW.alpha_reserved
            > scope_record.model_a_alpha_total
    ) THEN
        RAISE EXCEPTION 'MODEL_A validation budget exhausted' USING ERRCODE = '54000';
    END IF;

    IF NEW.model_family = 'MODEL_B' AND (
        scope_record.model_b_reserved_evaluation_count + NEW.evaluation_count
            > scope_record.model_b_max_evaluation_count
        OR scope_record.model_b_reserved_alpha + NEW.alpha_reserved
            > scope_record.model_b_alpha_total
    ) THEN
        RAISE EXCEPTION 'MODEL_B validation budget exhausted' USING ERRCODE = '54000';
    END IF;

    UPDATE strategy_training.training_validation_scopes
    SET reserved_evaluation_count = reserved_evaluation_count + NEW.evaluation_count,
        reserved_alpha = reserved_alpha + NEW.alpha_reserved,
        model_a_reserved_evaluation_count = model_a_reserved_evaluation_count
            + CASE WHEN NEW.model_family = 'MODEL_A' THEN NEW.evaluation_count ELSE 0 END,
        model_a_reserved_alpha = model_a_reserved_alpha
            + CASE WHEN NEW.model_family = 'MODEL_A' THEN NEW.alpha_reserved ELSE 0 END,
        model_b_reserved_evaluation_count = model_b_reserved_evaluation_count
            + CASE WHEN NEW.model_family = 'MODEL_B' THEN NEW.evaluation_count ELSE 0 END,
        model_b_reserved_alpha = model_b_reserved_alpha
            + CASE WHEN NEW.model_family = 'MODEL_B' THEN NEW.alpha_reserved ELSE 0 END
    WHERE validation_scope_id = NEW.validation_scope_id;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_iteration_metric_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    iteration_experiment_id uuid;
    evaluation_experiment_id uuid;
    frozen_iteration_id uuid;
BEGIN
    SELECT experiment_id INTO iteration_experiment_id
    FROM strategy_training.training_iterations
    WHERE iteration_id = NEW.iteration_id;

    IF NEW.partition = 'VALIDATION' THEN
        SELECT evaluation.experiment_id, freeze_record.iteration_id
        INTO evaluation_experiment_id, frozen_iteration_id
        FROM strategy_training.training_validation_evaluations evaluation
        JOIN strategy_training.training_final_candidate_freezes freeze_record
          ON freeze_record.final_candidate_freeze_id = evaluation.final_candidate_freeze_id
        WHERE evaluation.validation_evaluation_id = NEW.validation_evaluation_id;

        IF evaluation_experiment_id IS DISTINCT FROM iteration_experiment_id
           OR frozen_iteration_id IS DISTINCT FROM NEW.iteration_id THEN
            RAISE EXCEPTION 'VALIDATION metrics must reference their frozen candidate evaluation'
                USING ERRCODE = '23514';
        END IF;
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_validation_evaluation_insert()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    reservation_record strategy_training.training_validation_reservations%ROWTYPE;
    freeze_record strategy_training.training_final_candidate_freezes%ROWTYPE;
BEGIN
    SELECT * INTO reservation_record
    FROM strategy_training.training_validation_reservations
    WHERE validation_reservation_id = NEW.validation_reservation_id;

    SELECT * INTO freeze_record
    FROM strategy_training.training_final_candidate_freezes
    WHERE final_candidate_freeze_id = NEW.final_candidate_freeze_id;

    IF reservation_record.validation_scope_id <> NEW.validation_scope_id
       OR reservation_record.final_candidate_freeze_id <> NEW.final_candidate_freeze_id
       OR reservation_record.alpha_reserved <> NEW.alpha_used
       OR freeze_record.experiment_id <> NEW.experiment_id THEN
        RAISE EXCEPTION 'validation evaluation does not match reservation and frozen candidate'
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END
$$;

CREATE OR REPLACE FUNCTION strategy_training.guard_validation_scope_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'validation scopes cannot be deleted' USING ERRCODE = '55000';
    END IF;

    IF NEW.scope_hash IS DISTINCT FROM OLD.scope_hash
       OR NEW.partition_start_at IS DISTINCT FROM OLD.partition_start_at
       OR NEW.partition_end_at IS DISTINCT FROM OLD.partition_end_at
       OR NEW.ticker_pool_rule_version_id IS DISTINCT FROM OLD.ticker_pool_rule_version_id
       OR NEW.validation_protocol_version_id IS DISTINCT FROM OLD.validation_protocol_version_id
       OR NEW.max_evaluation_count IS DISTINCT FROM OLD.max_evaluation_count
       OR NEW.alpha_total IS DISTINCT FROM OLD.alpha_total
       OR NEW.model_a_max_evaluation_count IS DISTINCT FROM OLD.model_a_max_evaluation_count
       OR NEW.model_a_alpha_total IS DISTINCT FROM OLD.model_a_alpha_total
       OR NEW.model_b_max_evaluation_count IS DISTINCT FROM OLD.model_b_max_evaluation_count
       OR NEW.model_b_alpha_total IS DISTINCT FROM OLD.model_b_alpha_total
       OR NEW.reserved_evaluation_count < OLD.reserved_evaluation_count
       OR NEW.reserved_alpha < OLD.reserved_alpha
       OR NEW.model_a_reserved_evaluation_count < OLD.model_a_reserved_evaluation_count
       OR NEW.model_a_reserved_alpha < OLD.model_a_reserved_alpha
       OR NEW.model_b_reserved_evaluation_count < OLD.model_b_reserved_evaluation_count
       OR NEW.model_b_reserved_alpha < OLD.model_b_reserved_alpha THEN
        RAISE EXCEPTION 'validation scope identity and consumed budget are immutable'
            USING ERRCODE = '55000';
    END IF;

    RETURN NEW;
END
$$;

CREATE TRIGGER trg_training_experiment_insert_guard
BEFORE INSERT ON strategy_training.training_experiments
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_experiment_insert();

CREATE TRIGGER trg_training_experiment_config_binding_insert_guard
BEFORE INSERT ON strategy_training.training_experiment_config_bindings
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_experiment_config_binding_insert();

CREATE TRIGGER trg_training_experiment_config_binding_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_experiment_config_bindings
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_iteration_insert_guard
BEFORE INSERT ON strategy_training.training_iterations
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_iteration_insert();

CREATE TRIGGER trg_training_optimizer_run_insert_guard
BEFORE INSERT ON strategy_training.training_optimizer_runs
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_optimizer_run_insert();

CREATE TRIGGER trg_training_optimizer_checkpoint_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_optimizer_checkpoints
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_final_candidate_freeze_insert_guard
BEFORE INSERT ON strategy_training.training_final_candidate_freezes
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_final_candidate_freeze_insert();

CREATE TRIGGER trg_training_final_candidate_freeze_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_final_candidate_freezes
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_validation_scope_insert_guard
BEFORE INSERT ON strategy_training.training_validation_scopes
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_validation_scope_insert();

CREATE TRIGGER trg_training_validation_scope_mutation_guard
BEFORE UPDATE OR DELETE ON strategy_training.training_validation_scopes
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_validation_scope_mutation();

CREATE TRIGGER trg_training_validation_reservation_insert_guard
BEFORE INSERT ON strategy_training.training_validation_reservations
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_validation_reservation_insert();

CREATE TRIGGER trg_training_validation_reservation_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_validation_reservations
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_validation_evaluation_insert_guard
BEFORE INSERT ON strategy_training.training_validation_evaluations
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_validation_evaluation_insert();

CREATE TRIGGER trg_training_validation_evaluation_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_validation_evaluations
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_iteration_metrics_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_iteration_metrics
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_iteration_metric_insert_guard
BEFORE INSERT ON strategy_training.training_iteration_metrics
FOR EACH ROW EXECUTE FUNCTION strategy_training.guard_iteration_metric_insert();

CREATE TRIGGER trg_training_score_components_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_score_components
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

CREATE TRIGGER trg_training_state_transition_log_append_only
BEFORE UPDATE OR DELETE ON strategy_training.training_state_transition_log
FOR EACH ROW EXECUTE FUNCTION core.reject_training_append_only_mutation();

ALTER TABLE strategy_training.training_experiments OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_experiment_config_bindings OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_iterations OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_optimizer_runs OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_optimizer_checkpoints OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_final_candidate_freezes OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_validation_scopes OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_validation_reservations OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_validation_evaluations OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_iteration_metrics OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_score_components OWNER TO tb2_training_owner;
ALTER TABLE strategy_training.training_state_transition_log OWNER TO tb2_training_owner;

ALTER FUNCTION strategy_training.compute_validation_scope_hash(timestamptz, timestamptz, uuid)
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_experiment_insert() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_experiment_config_binding_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_iteration_insert() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_optimizer_run_insert() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_final_candidate_freeze_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_validation_scope_insert() OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_validation_reservation_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_validation_evaluation_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_iteration_metric_insert()
OWNER TO tb2_training_owner;
ALTER FUNCTION strategy_training.guard_validation_scope_mutation()
OWNER TO tb2_training_owner;

REVOKE ALL ON ALL TABLES IN SCHEMA strategy_training FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA strategy_training FROM PUBLIC;

GRANT SELECT ON
    strategy_training.training_experiments,
    strategy_training.training_experiment_config_bindings,
    strategy_training.training_iterations,
    strategy_training.training_optimizer_runs,
    strategy_training.training_optimizer_checkpoints,
    strategy_training.training_final_candidate_freezes,
    strategy_training.training_state_transition_log
TO tb2_training_rw;

GRANT SELECT ON
    strategy_training.training_experiments,
    strategy_training.training_experiment_config_bindings,
    strategy_training.training_iterations,
    strategy_training.training_optimizer_runs,
    strategy_training.training_optimizer_checkpoints,
    strategy_training.training_final_candidate_freezes,
    strategy_training.training_validation_scopes,
    strategy_training.training_validation_reservations,
    strategy_training.training_validation_evaluations,
    strategy_training.training_iteration_metrics,
    strategy_training.training_score_components,
    strategy_training.training_state_transition_log
TO tb2_training_evaluator;

GRANT SELECT ON
    strategy_training.training_experiments,
    strategy_training.training_experiment_config_bindings,
    strategy_training.training_iterations,
    strategy_training.training_optimizer_runs,
    strategy_training.training_optimizer_checkpoints,
    strategy_training.training_final_candidate_freezes,
    strategy_training.training_validation_scopes,
    strategy_training.training_validation_reservations,
    strategy_training.training_state_transition_log
TO tb2_training_orchestrator;

INSERT INTO core.schema_migrations (version, checksum_sha256, description)
VALUES (
    '021_training_experiments_validation',
    encode(digest('auto_trade_v2_021_training_experiments_validation_v1', 'sha256'), 'hex'),
    'Add TRAIN experiment facts, optimizer checkpoints and shared one-pass validation budgets'
)
ON CONFLICT (version) DO NOTHING;

COMMIT;
