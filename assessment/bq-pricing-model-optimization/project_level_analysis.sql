-- ###########################################################################
-- Query Description
--
-- This query calculates the potential cost savings for each BigQuery job by
-- identifying the optimal pricing model (on-demand vs. slot-based) that could
-- have been used, at the project level. It helps you understand how much you
-- could save by choosing the best available pricing option for your workloads
-- within a specific GCP project.
--
-- How to Execute:
--   - Run this query separately for each region you use in BigQuery, and for each
--     project you want to analyze.
--   - You must have at least the BigQuery Resource Viewer (roles/bigquery.resourceViewer) role on the project
--     to execute this query for that project.
--
-- Slot Hour Price:
--   - For the estimated_slot_hour_price parameter, use the official list price
--     for your region from the BigQuery Pricing page:
--     https://cloud.google.com/bigquery/pricing
--   - If your organization has custom pricing (e.g., due to commitments or
--     negotiated rates), check your billing account in the GCP Billing Console
--     for the actual prices. Commitments can reduce your average slot hour price.
-- ###########################################################################
-- Parameters:
--   ${project_id}: The GCP project ID to analyze
--   ${region}: The region to analyze
--   ${estimated_slot_hour_price}: The estimated hourly cost of a BigQuery slot
WITH base AS (
  SELECT 
    *
    , total_bytes_billed / 1024/ 1024 / 1024 / 1024 * 6.25 AS ondemand_cost
    , IF(reservation_id IS NULL OR reservation_id = 'default-pipeline', 'on_demand', 'slot_based') AS actual_pricing_model
    , total_slot_ms/1000/3600 * ${estimated_slot_hour_price} / 0.7 AS slot_based_cost
  FROM `${project_id}`.region-${region}.INFORMATION_SCHEMA.JOBS
  WHERE TIMESTAMP_TRUNC(creation_time, DAY) >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY) 
),

add_optimal_pricing AS (
  SELECT 
    *
    , IF(ondemand_cost < slot_based_cost, 'on_demand', 'slot_based') AS optimal_pricing_model
    , IF(ondemand_cost < slot_based_cost, ondemand_cost, slot_based_cost) AS optimal_cost
    , IF(actual_pricing_model = 'on_demand', ondemand_cost, slot_based_cost) AS actual_cost
  FROM base
),

add_saving AS (
  SELECT
    *
    , actual_cost - optimal_cost AS possible_saving
  FROM add_optimal_pricing
)

SELECT 
  user_email
  , COUNT(*) AS number_of_jobs
  , SUM(ondemand_cost) AS ondemand_cost
  , SUM(slot_based_cost) AS slot_based_cost
  , SUM(optimal_cost) AS optimal_cost
  , SUM(possible_saving) AS possible_saving
  , FORMAT('%s%%', CAST(ROUND(SAFE_DIVIDE(SUM(possible_saving), SUM(actual_cost))* 100, 2) AS STRING)) AS possible_saving_perc
  , COUNTIF(optimal_pricing_model != actual_pricing_model) AS number_of_jobs_to_change
FROM add_saving
GROUP BY user_email
ORDER BY possible_saving DESC 