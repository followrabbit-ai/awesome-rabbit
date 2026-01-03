#!/bin/bash

source ./rabbit_bq.sh

if [ -f .env ]; then
  # Export variables from .env file, ignoring commented lines
  export $(grep -v '^#' .env | xargs)
fi


export BQ_OPTIMIZER_DEFAULT_PRICING_MODE=on_demand
echo "--------------------------------"
echo "Executing a query that should be assigned to reservation from on-demand pricing..."
rabbit-bq query -q -n 0 --replace --nouse_legacy_sql --debug_mode "SELECT block_hash FROM \`bigquery-public-data.crypto_bitcoin_cash.transactions\` LIMIT 1000"
echo "--------------------------------"

echo "--------------------------------"
export BQ_OPTIMIZER_DEFAULT_PRICING_MODE=slot_based
echo "Executing a query that should be kept on slot-based pricing..."
rabbit-bq query -q -n 0 --replace --nouse_legacy_sql --debug_mode "SELECT block_hash FROM \`bigquery-public-data.crypto_bitcoin_cash.transactions\` LIMIT 1000"
echo "--------------------------------"

echo "--------------------------------"
export BQ_OPTIMIZER_DEFAULT_PRICING_MODE=slot_based
echo "Executing a query that should be assigned to on-demand pricing from slot-based pricing..."
rabbit-bq query --nouse_legacy_sql --debug_mode "WITH RECURSIVE
dna_strings AS (
  SELECT 1 AS lenght, c AS dna_string FROM UNNEST(['A', 'C', 'G', 'T']) AS c
  UNION ALL
  SELECT lenght + 1, CONCAT(dna_string, c)
  FROM dna_strings
  CROSS JOIN UNNEST(['A', 'C', 'G', 'T']) AS c
  WHERE lenght <= 10
)
SELECT * FROM dna_strings
WHERE lenght = 11
ORDER BY dna_string
LIMIT 10000000"
echo "--------------------------------"

echo "--------------------------------"
export BQ_OPTIMIZER_DEFAULT_PRICING_MODE=on_demand
echo "Executing a query that should be kept on on-demand pricing"

rabbit-bq query --nouse_legacy_sql --debug_mode "WITH RECURSIVE
dna_strings AS (
  SELECT 1 AS lenght, c AS dna_string FROM UNNEST(['A', 'C', 'G', 'T']) AS c
  UNION ALL
  SELECT lenght + 1, CONCAT(dna_string, c)
  FROM dna_strings
  CROSS JOIN UNNEST(['A', 'C', 'G', 'T']) AS c
  WHERE lenght <= 10
)
SELECT * FROM dna_strings
WHERE lenght = 11
ORDER BY dna_string
LIMIT 10000000"
echo "--------------------------------"

echo "--------------------------------"
echo "Executing a query without historical data"
rabbit-bq query -q -n 0 --replace --nouse_legacy_sql --debug_mode "SELECT CURRENT_TIMESTAMP()"
echo "--------------------------------"

echo "--------------------------------"
echo "Executing a query in dry run mode"
rabbit-bq query -q -n 0 --replace --nouse_legacy_sql --dry_run --debug_mode "SELECT block_hash FROM \`bigquery-public-data.crypto_bitcoin_cash.transactions\` LIMIT 1000"
echo "--------------------------------"