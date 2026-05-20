-- Category 6a: failed jobs grouped by failure reason, excluding user/query
-- errors so what remains is dominated by capacity / resource pressure.
-- slot_hours quantifies the slots burned on jobs that ultimately failed.
SELECT
  error_result.reason,
  error_result.location,
  error_result.debug_info,
  CASE
    WHEN error_result.message LIKE 'Query exceeded limit for bytes billed:%'
      THEN 'Query exceeded limit for bytes billed'
    WHEN error_result.message LIKE 'Resources exceeded during query execution: The query could not be executed in the allotted memory. Peak usage%'
      THEN 'Resources exceeded during query execution: The query could not be executed in the allotted memory. Peak usage'
    ELSE error_result.message
  END                                  AS message,
  reservation_id IS NOT NULL           AS on_reservation,
  SUM(total_slot_ms) / 1000 / 3600     AS slot_hours
FROM `${project_id}`.`region-${region}`.INFORMATION_SCHEMA.JOBS_BY_PROJECT
WHERE error_result IS NOT NULL
  AND error_result.reason NOT IN (
      'accessDenied', 'invalidQuery', 'invalid', 'notFound', 'responseTooLarge',
      'backendError', 'internalError', 'duplicate', 'quotaExceeded', 'rateLimitExceeded')
  AND NOT (error_result.reason = 'stopped'
           AND error_result.message = 'Job execution was cancelled: User requested cancellation')
  AND creation_time >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL ${lookback_days} DAY)
GROUP BY ALL
ORDER BY slot_hours DESC, error_result.reason, message;
