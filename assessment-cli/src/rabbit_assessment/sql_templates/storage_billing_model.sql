-- Category 5: storage billing-model optimization (LOGICAL vs. PHYSICAL).
-- Per-dataset comparison of the current billing model against the alternative.
-- The four storage rates are tool parameters (USD or the configured currency
-- per GiB-month); override them per region via the pricing config.
WITH
storage AS (
  SELECT
    project_id,
    table_schema                                        AS dataset_id,
    COUNT(*)                                             AS table_count,
    SUM(active_logical_bytes)                            AS active_logical_bytes,
    SUM(long_term_logical_bytes)                         AS long_term_logical_bytes,
    SUM(active_physical_bytes)                           AS active_physical_bytes,
    SUM(long_term_physical_bytes)                        AS long_term_physical_bytes,
    SUM(time_travel_physical_bytes)                      AS time_travel_physical_bytes,
    SUM(fail_safe_physical_bytes)                        AS fail_safe_physical_bytes
  FROM `${project_id}`.`region-${region}`.INFORMATION_SCHEMA.TABLE_STORAGE
  WHERE deleted = FALSE
    AND table_type IN ('BASE TABLE', 'MATERIALIZED VIEW', 'SNAPSHOT')
  GROUP BY project_id, dataset_id
),
models AS (
  SELECT
    schema_name      AS dataset_id,
    option_value     AS storage_billing_model
  FROM `${project_id}`.`region-${region}`.INFORMATION_SCHEMA.SCHEMATA_OPTIONS
  WHERE option_name = 'storage_billing_model'
),
priced AS (
  SELECT
    s.project_id,
    s.dataset_id,
    s.table_count,
    -- A dataset with no storage_billing_model option uses the project/org
    -- default; assume ${default_storage_billing_model} (configurable).
    COALESCE(m.storage_billing_model, '${default_storage_billing_model}') AS current_billing_model,

    s.active_logical_bytes,
    s.long_term_logical_bytes,
    s.active_physical_bytes + s.time_travel_physical_bytes + s.fail_safe_physical_bytes
                                                  AS active_physical_billed_bytes,
    s.long_term_physical_bytes,

    SAFE_DIVIDE(s.active_logical_bytes, POW(2, 30)) * ${storage_logical_active_price}
      + SAFE_DIVIDE(s.long_term_logical_bytes, POW(2, 30)) * ${storage_logical_lt_price}
                                                  AS monthly_cost_logical,

    SAFE_DIVIDE(s.active_physical_bytes + s.time_travel_physical_bytes + s.fail_safe_physical_bytes,
                POW(2, 30)) * ${storage_physical_active_price}
      + SAFE_DIVIDE(s.long_term_physical_bytes, POW(2, 30)) * ${storage_physical_lt_price}
                                                  AS monthly_cost_physical
  FROM storage s
  LEFT JOIN models m USING (dataset_id)
)
SELECT
  project_id,
  dataset_id,
  current_billing_model,
  table_count,
  ROUND(SAFE_DIVIDE(active_logical_bytes,         POW(2, 30)), 2) AS active_logical_gib,
  ROUND(SAFE_DIVIDE(long_term_logical_bytes,      POW(2, 30)), 2) AS long_term_logical_gib,
  ROUND(SAFE_DIVIDE(active_physical_billed_bytes, POW(2, 30)), 2) AS active_physical_billed_gib,
  ROUND(SAFE_DIVIDE(long_term_physical_bytes,     POW(2, 30)), 2) AS long_term_physical_gib,
  ROUND(SAFE_DIVIDE(active_logical_bytes + long_term_logical_bytes, POW(2, 30)), 2) AS total_logical_gib,
  ROUND(SAFE_DIVIDE(active_physical_billed_bytes + long_term_physical_bytes, POW(2, 30)), 2) AS total_physical_billed_gib,
  ROUND(SAFE_DIVIDE(active_physical_billed_bytes + long_term_physical_bytes,
                    NULLIF(active_logical_bytes + long_term_logical_bytes, 0)), 3) AS physical_to_logical_ratio,
  ROUND(monthly_cost_logical,  2) AS monthly_cost_logical,
  ROUND(monthly_cost_physical, 2) AS monthly_cost_physical,
  ROUND(IF(current_billing_model = 'PHYSICAL', monthly_cost_physical, monthly_cost_logical), 2)
                                  AS monthly_cost_current,
  -- Saving = current cost - cheapest available model. Always >= 0 (it is 0
  -- when the dataset is already on the optimal model). NOT "other model -
  -- current", which goes negative whenever the current model is the cheaper one.
  ROUND(
    IF(current_billing_model = 'PHYSICAL', monthly_cost_physical, monthly_cost_logical)
    - LEAST(monthly_cost_logical, monthly_cost_physical),
    2)                            AS potential_monthly_saving,
  CASE
    WHEN current_billing_model = 'PHYSICAL'
         AND monthly_cost_logical  < monthly_cost_physical THEN 'SWITCH_TO_LOGICAL'
    WHEN current_billing_model = 'LOGICAL'
         AND monthly_cost_physical < monthly_cost_logical  THEN 'SWITCH_TO_PHYSICAL'
    ELSE 'KEEP'
  END                             AS recommendation
FROM priced
ORDER BY potential_monthly_saving DESC;
