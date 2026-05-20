-- Category 2: all BigQuery reservations administered by this project.
-- INFORMATION_SCHEMA.RESERVATIONS only returns rows in the project that OWNS
-- the reservation (the administration project); workload projects see nothing.
-- SELECT * keeps the tool resilient to edition-dependent column differences.
SELECT *
FROM `${project_id}`.`region-${region}`.INFORMATION_SCHEMA.RESERVATIONS;
