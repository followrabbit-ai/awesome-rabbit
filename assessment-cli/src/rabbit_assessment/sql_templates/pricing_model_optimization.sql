-- Category 4: job pricing-model optimization (on-demand vs. slot-based).
-- Derived from assessment/bq-pricing-model-optimization/project_level_analysis.sql
-- Changes vs. the original:
--   * source view JOBS -> JOBS_BY_PROJECT (whole-project view)
--   * the fixed 30-day window is now a tool parameter (lookback_days)
--   * added (statement_type IS NULL OR statement_type != 'SCRIPT') to drop
--     duplicate script-child rows
WITH base AS (
  SELECT
    *
    , total_bytes_billed / 1024 / 1024 / 1024 / 1024 * ${ondemand_price} AS ondemand_cost
    , IF(reservation_id IS NULL OR reservation_id = 'default-pipeline', 'on_demand', 'slot_based') AS actual_pricing_model
    , total_slot_ms / 1000 / 3600 * ${slot_hour_price} / 0.7 AS slot_based_cost
  FROM `${project_id}`.`region-${region}`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
  WHERE TIMESTAMP_TRUNC(creation_time, DAY) >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL ${lookback_days} DAY)
    AND job_type = 'QUERY'
    AND (statement_type IS NULL OR statement_type != 'SCRIPT')
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
  , FORMAT('%s%%', CAST(ROUND(SAFE_DIVIDE(SUM(possible_saving), SUM(actual_cost)) * 100, 2) AS STRING)) AS possible_saving_perc
  , COUNTIF(optimal_pricing_model != actual_pricing_model) AS number_of_jobs_to_change
FROM add_saving
GROUP BY user_email
ORDER BY possible_saving DESC;
