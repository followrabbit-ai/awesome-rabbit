-- Category 7: reservation utilization / waste for reservations administered by
-- this project. Derived from assessment/bigquery-reservation-waste/waste_analysis.sql
-- Changes vs. the original:
--   * utilized capacity comes from the JOBS_BY_PROJECT view (per-job
--     total_slot_ms) instead of JOBS_TIMELINE_BY_ORGANIZATION
--   * RESERVATION_CHANGES is read from this project (every visible project is
--     treated as a potential administration project)
--   * the fixed 30-day window is now a tool parameter (lookback_days)
-- NOTE: utilized_slot_hours only counts jobs in THIS project, so utilization is
-- undercounted when a reservation also serves other projects. report.py
-- additionally aggregates utilization by reservation_id across all scanned
-- projects to correct for this.
WITH
cutoff AS (
  SELECT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL ${lookback_days} DAY) AS cutoff_timestamp
),

utilized_capacity AS (
  SELECT
    reservation_id
    , SUM(total_slot_ms) / 1000 / 3600 AS utilized_slot_hours
  FROM `${project_id}`.`region-${region}`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
  WHERE creation_time >= (SELECT cutoff_timestamp FROM cutoff)
    AND job_type = 'QUERY'
    AND (statement_type IS NULL OR statement_type != 'SCRIPT')
    AND reservation_id IS NOT NULL
  GROUP BY reservation_id
),

reservation_history AS (
  SELECT
    CONCAT(project_id, ':${region}.', reservation_name) AS reservation_id
    , IF(change_timestamp < (SELECT cutoff_timestamp FROM cutoff),
         (SELECT cutoff_timestamp FROM cutoff), change_timestamp) AS valid_from
    , COALESCE(LEAD(change_timestamp) OVER (
        PARTITION BY project_id, reservation_name ORDER BY change_timestamp),
        CURRENT_TIMESTAMP()) AS valid_to
    , autoscale.current_slots
    , slot_capacity
    , slot_capacity + autoscale.current_slots AS billed_capacity
  FROM `${project_id}`.`region-${region}`.INFORMATION_SCHEMA.RESERVATION_CHANGES
  WHERE autoscale.current_slots IS NOT NULL
    AND action != 'DELETE'
  QUALIFY valid_to >= (SELECT cutoff_timestamp FROM cutoff)
),

billed_capacity_history AS (
  SELECT
    *
    , TIMESTAMP_DIFF(valid_to, valid_from, SECOND) * billed_capacity / 3600 AS period_billed_capacity
  FROM reservation_history
),

billed_capacity AS (
  SELECT
    reservation_id
    , SUM(period_billed_capacity) AS billed_slot_hours
  FROM billed_capacity_history
  GROUP BY reservation_id
)

SELECT
  b.reservation_id
  , b.billed_slot_hours
  , COALESCE(u.utilized_slot_hours, 0) AS utilized_slot_hours
  , FORMAT('%s%%', CAST(ROUND((1 - SAFE_DIVIDE(COALESCE(u.utilized_slot_hours, 0), b.billed_slot_hours)) * 100, 2) AS STRING)) AS waste
-- LEFT JOIN so a fully idle reservation (no jobs) still appears as 100% waste.
FROM billed_capacity b
LEFT JOIN utilized_capacity u
  ON LOWER(b.reservation_id) = LOWER(u.reservation_id)
ORDER BY b.billed_slot_hours DESC;
