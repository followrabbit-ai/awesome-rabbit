-- ###########################################################################
-- Query Description
--
-- This query calculates the potential cost savings for each BigQuery project by
-- identifying the optimal pricing model (on-demand vs. slot-based) that could
-- have been used. It helps you understand how much you could save by choosing
-- the best available pricing option for your project.
--
-- How to Execute:
--   - Run this query separately for each region you use in BigQuery.
--   - You must have at least the BigQuery Resource Viewer (roles/bigquery.resourceViewer) role at the organization
--     to execute this query across all projects.
--
-- Note: it uses the list price in the US region which is $6.25 / 1 TB for on-demand cost
-- and $0.06 / 1 slot-hour for the Enterprise edition. 
-- Please change this as well if your region is different or if you have a discounted price based on your Google contract. 
--
-- Parameters:
--   ${BQ_REGION}: The region to analyze
-- ###########################################################################
WITH
 jobs AS (
   SELECT
     project_id,
     error_result,
     total_bytes_billed / 1024 / 1024 / 1024 / 1024 total_tib_billed,
     CASE statement_type
       WHEN 'CREATE_MODEL'
         THEN
           50
           * 6.25  # $6.25 / 1 tebibyte in the US (change this based on your own pricing and region)
       ELSE
         6.25  # $6.25 / 1 tebibyte in the US (change this based on your own pricing and region)
       END AS multiplier,
     total_slot_ms
   FROM `region-${BQ_REGION}`.INFORMATION_SCHEMA.JOBS_BY_ORGANIZATION
   WHERE
     job_type = "QUERY"
     AND statement_type <> 'SCRIPT'
     AND reservation_id IS NULL
     AND creation_time > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
 ),
 cost_per_project AS (
   SELECT
     project_id,
     SUM(total_tib_billed * multiplier) AS on_demand_cost,
     SUM(total_slot_ms) / 1000 / 60 / 60 / 0.7
       * 0.06  # $0.06 / 1 slot-hour in the US for Enterprise Edition (change this based on your own pricing and region)
       AS reservation_cost
   FROM jobs
   GROUP BY 1
   ORDER BY 1 DESC
 ),
 total_savings AS (
   SELECT
     project_id,
     on_demand_cost,
     reservation_cost,
     on_demand_cost - reservation_cost AS total_savings
   FROM
     cost_per_project
   WHERE (on_demand_cost - reservation_cost) > 50
 ),
 slot_statistics AS (
   SELECT
     AVG(period_slot_ms / 1000) AS avg_slot_usage,
     MAX(period_slot_ms / 1000) AS max_slot_usage,
     APPROX_QUANTILES(period_slot_ms / 1000, 100)[OFFSET(50)]
       AS median_slot_usage,
     APPROX_QUANTILES(period_slot_ms / 1000, 100)[OFFSET(90)]
       AS percentile_90_slot_usage,
     APPROX_QUANTILES(period_slot_ms / 1000, 100)[OFFSET(95)]
       AS percentile_95_slot_usage,
     APPROX_QUANTILES(period_slot_ms / 1000, 100)[OFFSET(99)]
       AS percentile_99_slot_usage,
   FROM `region-${BQ_REGION}`.INFORMATION_SCHEMA.JOBS_TIMELINE_BY_ORGANIZATION
   WHERE
     job_type = "QUERY"
     AND statement_type <> 'SCRIPT'
     AND reservation_id IS NULL
     AND job_creation_time > TIMESTAMP_SUB(
       CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
     AND project_id IN (SELECT project_id FROM total_savings)
 )

# list the projects to change to Reservations
SELECT * FROM total_savings ORDER BY total_savings DESC