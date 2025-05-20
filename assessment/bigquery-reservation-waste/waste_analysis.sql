-- ###########################################################################
-- Query Description
--
-- This query calculates the slot waste for each BigQuery reservation by comparing
-- the billed slot hours to the utilized slot hours. It helps you identify underutilized
-- reservations and potential cost savings opportunities with the Rabbit BQ Autoscaler feature.
--
-- How to Execute:
--   - Run this query for every region and reservation project pair where there is any reservation.
--   - You must have at least the BigQuery Resource Viewer (roles/bigquery.resourceViewer) role
--     at the organization or project level to execute this query.
--
-- Parameters:
--   ${region}: The region to analyze
--   {reservationProjectId}: The project ID where the reservation is located
-- ###########################################################################
WITH
cutoff AS (
  SELECT TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY) AS cutoff_timestamp
),

utilized_capacity AS 
(
  SELECT
    reservation_id
    , SUM(period_slot_ms) / 1000 / 3600 as utilized_slot_hours,
  FROM `region-${region}`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_ORGANIZATION
  WHERE period_start >= (SELECT * FROM cutoff)
    AND job_creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 31 DAY) -- to utilize the partitioning
    AND job_type = 'QUERY'
    AND (statement_type != "SCRIPT" OR statement_type IS NULL)
  GROUP BY reservation_id
),

reservation_history AS
(
  SELECT
    CONCAT(project_id, ":${region}.",reservation_name) AS reservation_id
    , IF(change_timestamp < (SELECT * FROM cutoff), (SELECT * FROM cutoff), change_timestamp) AS valid_from
    , COALESCE(LEAD(change_timestamp) OVER (PARTITION BY project_id, reservation_name ORDER BY change_timestamp), CURRENT_TIMESTAMP()) AS valid_to
    , autoscale.current_slots
    , slot_capacity
    , slot_capacity + autoscale.current_slots AS billed_capacity
  FROM `{reservationProjectId}.region-${region}`.INFORMATION_SCHEMA.RESERVATION_CHANGES
  WHERE autoscale.current_slots IS NOT NULL
    AND action != 'DELETE'
  QUALIFY valid_to >= (SELECT * FROM cutoff)
),

billed_capacity_history AS (
  SELECT 
    *
    , TIMESTAMP_DIFF(valid_to, valid_from, SECOND) * billed_capacity / 3600  AS period_billed_capacity
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
  *
  , FORMAT('%s%%', CAST(ROUND((1 - (SAFE_DIVIDE(utilized_slot_hours, billed_slot_hours)))* 100, 2) AS STRING)) AS waste
FROM billed_capacity
JOIN utilized_capacity USING(reservation_id)