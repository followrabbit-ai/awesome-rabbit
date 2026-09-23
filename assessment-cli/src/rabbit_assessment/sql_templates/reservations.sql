-- Category 2: all BigQuery reservations administered by this project.
-- INFORMATION_SCHEMA.RESERVATIONS only returns rows in the project that OWNS
-- the reservation (the administration project); workload projects see nothing.
-- Explicit scalar columns only (the autoscale STRUCT is flattened, ARRAY
-- columns are omitted) so the result is plain CSV for both the Python and
-- Bash tools.
SELECT
  project_id,
  project_number,
  reservation_name,
  edition,
  slot_capacity,
  ignore_idle_slots,
  autoscale.current_slots AS autoscale_current_slots,
  autoscale.max_slots     AS autoscale_max_slots,
  max_slots,
  scaling_mode,
  target_job_concurrency,
  primary_location,
  secondary_location,
  original_primary_location
FROM `${project_id}`.`region-${region}`.INFORMATION_SCHEMA.RESERVATIONS;
