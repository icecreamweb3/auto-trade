\set ON_ERROR_STOP on
\pset pager off

-- Governed replacement for the original 30-effective-day TRAIN dataset.
-- Adds 15 effective days while preserving the original fold anchor and the
-- complete 24-hour label window. Required manifest variables are forwarded to
-- build-august-train-dataset.sql by psql.
\set warmup_start '2026-07-24 22:20:00+00'
\set eligible_start '2026-08-01 00:00:00+00'
\set dataset_eligible_end '2026-09-15 00:00:00+00'
\set label_window_end '2026-09-16 00:00:00+00'
\set eligible_end '2026-09-16 00:00:00+00'
\set partition_start '2026-08-01 00:00:00+00'
\set partition_end '2026-09-16 00:00:00+00'
\set source_as_of '2026-11-06 05:59:10.897368+00'
\set visibility_cutoff '2026-07-31 00:00:00+00'
\set top_n 50
\set actor_user_id 'b123d0af-5004-4e69-a327-24532a1ae57c'
-- This expands the governed range, so it is a distinct dataset identity rather
-- than a source-revision replacement of the original August dataset.
\set supersedes_dataset_id ''
\set dataset_builder 'EXTENDED_45_DAY_TRAIN_A0_V1'
\set resource_assessment 'EXTENDED_45_DAY_TRAIN_A0_DAILY_BOUNDED_V1'
\set estimated_member_rows 764200
\set bounded_query_days 54
\set transition_reason 'A0 extended 45-day TRAIN coverage, historical pool, resources, and manifest passed'
\set run_command 'psql -f scripts/build-extended-train-dataset.sql'

\ir build-august-train-dataset.sql
