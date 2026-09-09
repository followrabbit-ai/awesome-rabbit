-- Category 3: BigQuery capacity-commitment change history for this project.
-- CAPACITY_COMMITMENT_CHANGES retains roughly the last 41 days of changes and,
-- like RESERVATIONS, only resolves in the administration project.
-- EXCEPT(failure_status) drops the one STRUCT column so the result is plain
-- CSV for both the Python and Bash tools (failure detail is low value here).
SELECT * EXCEPT (failure_status)
FROM `${project_id}`.`region-${region}`.INFORMATION_SCHEMA.CAPACITY_COMMITMENT_CHANGES
ORDER BY change_timestamp;
