-- Category 6b: cost impact of ALL failed jobs grouped by failure reason.
-- cost = slot_hours priced at ${slot_hour_price} (configured slot-hour price).
SELECT
  error_result.reason,
  SUM(total_slot_ms) / 1000 / 3600                        AS slot_hours,
  SUM(total_slot_ms) / 1000 / 3600 * ${slot_hour_price}   AS cost
FROM `${project_id}`.`region-${region}`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE error_result IS NOT NULL
  AND error_result.reason IS NOT NULL
  -- Top-level jobs only: a SCRIPT's total_slot_ms already includes every
  -- child statement, so counting parent + children double-counts the slots.
  AND parent_job_id IS NULL
  AND creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL ${lookback_days} DAY)
GROUP BY ALL
ORDER BY slot_hours DESC, error_result.reason;
