# Rabbit BigQuery Job Optimizer - Bash Integration

A bash function that automatically optimizes BigQuery queries using the Rabbit API before execution. The optimizer determines whether queries should run on-demand or in a reservation based on cost analysis, and applies the optimal configuration.

## Features

- **Automatic Cost Optimization**: Analyzes queries and recommends the most cost-effective execution mode (on-demand vs reservation)
- **Reservation Assignment**: Automatically assigns queries to reservations when cheaper
- **Label Tracking**: Adds optimization tracking labels to jobs
- **Fallback Support**: If optimization fails, falls back to original query configuration
- **Drop-in Replacement**: Easy to replace `bq query` with `rabbit-bq query` in existing scripts

## Prerequisites

- `bq` CLI tool installed and configured
- `jq` installed (for JSON processing)
- `curl` installed (for API calls)
- Rabbit API key

## Installation

1. Source the script in your bash environment:

```bash
source rabbit_bq.sh
```

Or add it to your `.bashrc` or `.bash_profile`:

```bash
echo 'source /path/to/rabbit_bq.sh' >> ~/.bashrc
```

2. Set up environment variables (see [Configuration](#configuration))

## Configuration

### Environment Variables

| Variable | Required | Description | Default |
|----------|----------|-------------|---------|
| `RABBIT_API_KEY` | Yes | Your Rabbit API key | - |
| `RABBIT_API_URL` | No | Rabbit API endpoint URL | `https://api.followrabbit.ai/bq-job-optimizer/v1/optimize-job` |
| `BQ_OPTIMIZER_DEFAULT_PRICING_MODE` | Yes | Default pricing mode: `"on_demand"` or `"slot_based"` | - |
| `BQ_OPTIMIZER_RESERVATION_IDS` | Yes | Comma-separated list of reservation IDs in format `project_id:region.reservation_name` | - |

**Command Line Flags:**
- `--debug_mode` - Show full API request/response for debugging

**Quick Setup:**

```bash
export RABBIT_API_KEY="your_api_key_here"
export BQ_OPTIMIZER_DEFAULT_PRICING_MODE="on_demand"
export BQ_OPTIMIZER_RESERVATION_IDS="my-project:us-central1.my-reservation-us,my-project:europe-west1.my-reservation-eu"
```

Get your API key from https://app.followrabbit.ai or your Rabbit admin.

See `sample.env` for a template.

### Running the Example Script

The `example.sh` script demonstrates various optimization scenarios. To run it:

1. **Create a `.env` file** with your specific environment variables:
   ```bash
   cp sample.env .env
   ```
   Then edit `.env` and fill in your values:
   - `RABBIT_API_KEY`: Your Rabbit API key
   - `BQ_OPTIMIZER_DEFAULT_PRICING_MODE`: Your default pricing mode (`on_demand` or `slot_based`)
   - `BQ_OPTIMIZER_RESERVATION_IDS`: Your comma-separated reservation IDs in format `project_id:region.reservation_name`

2. **Execute the script**:
   ```bash
   ./example.sh
   ```

The example script will run several queries demonstrating:
- Queries assigned to reservations from on-demand pricing
- Queries kept on slot-based pricing
- Queries assigned to on-demand pricing from slot-based pricing
- Queries kept on on-demand pricing
- Queries without historical data

All examples run with `--debug_mode` enabled to show the full API request and response.

## Usage

### Basic Usage

Replace `bq query` with `rabbit-bq query`:

```bash
# Before
bq query --use_legacy_sql=false "SELECT * FROM my_table"

# After
rabbit-bq query --use_legacy_sql=false "SELECT * FROM my_table"
```

### With Destination Table

```bash
rabbit-bq query \
  -q \
  -n 0 \
  --replace \
  --nouse_legacy_sql \
  --destination_table my_dataset.my_table \
  "SELECT * FROM source_table"
```

### Multi-line Queries

```bash
rabbit-bq query --nouse_legacy_sql --destination_table metrics.daily_stats "
  SELECT
    DATE(created_at) as date,
    COUNT(*) as count
  FROM events
  GROUP BY date
"
```

### Reading from stdin

```bash
echo "SELECT * FROM my_table" | rabbit-bq query --nouse_legacy_sql -
```

### All Standard bq Query Flags Supported

The function supports all standard `bq query` flags:

- `-q`, `--quiet`: Suppress informational messages
- `-n`, `--max_rows`: Limit number of rows returned
- `--replace`: Overwrite destination table
- `--destination_table`: Specify destination table
- `--nouse_legacy_sql`: Use standard SQL (default)
- `--use_legacy_sql`: Use legacy SQL
- `--label=KEY:VALUE`: Add labels to the job
- `--reservation_id=RESERVATION_ID`: Specify reservation (will be overridden if optimization recommends different)
- And all other `bq query` flags

## How It Works

1. **Query Extraction**: Extracts the SQL query from command arguments
2. **API Call**: Sends query to Rabbit API for optimization analysis
3. **Optimization**: API analyzes cost and recommends:
   - Reservation assignment (if cheaper)
   - On-demand execution (if cheaper)
   - Adds tracking labels
4. **Execution**: Executes query with optimized configuration:
   - Adds `--reservation_id` if recommended
   - Adds `--label` flags from optimization
5. **Fallback**: If optimized query fails, retries with original configuration

## Examples

### Example 1: Simple Query

```bash
rabbit-bq query "SELECT COUNT(*) FROM my_dataset.my_table"
```

### Example 2: With All Flags (from your script)

```bash
rabbit-bq query \
  -q \
  -n 0 \
  --replace \
  --nouse_legacy_sql \
  --destination_table metrics.bq_daily_average_slot_usage \
  "
  SELECT
    TIMESTAMP_TRUNC(jbo.period_start, HOUR) AS usage_time,
    EXTRACT(DATE FROM jbo.period_start) AS usage_date,
    job_id,
    project_id,
    SUM(jbo.period_slot_ms) / (1000 * 60 * 60) AS average_hourly_slot_usage
  FROM \`project\`.\`region-us\`.INFORMATION_SCHEMA.JOBS_TIMELINE jbo
  WHERE (jbo.statement_type != 'SCRIPT' OR jbo.statement_type IS NULL)
  GROUP BY 1,2,3,4
  "
```

### Example 3: With Custom Labels

```bash
rabbit_bq query \
  --label=environment:production \
  --label=team:analytics \
  "SELECT * FROM my_table"
```

## Optimization Configuration

The optimizer requires configuration of default pricing mode and reservation IDs. It will:
- Compare on-demand vs reservation pricing for each query
- Assign queries to reservations when cheaper
- Use on-demand when cheaper
- Add tracking labels

**Default Pricing Mode:**
- `"on_demand"`: Prefers on-demand, switches to reservation only if cheaper
- `"slot_based"`: Prefers reservation, switches to on-demand only if cheaper

**Reservation IDs:**
Provide a comma-separated list of reservation IDs in the format:
```
project_id:region.reservation_name
```

Example:
```bash
export BQ_OPTIMIZER_DEFAULT_PRICING_MODE="on_demand"
export BQ_OPTIMIZER_RESERVATION_IDS="my-project:us-central1.my-reservation-us,my-project:europe-west1.my-reservation-eu"
```

**Note:** The reservation ID format is `project_id:region.reservation_name` (e.g., `fpl-data-rsrvtn-pl-prd-ef99:asia-southeast2.kvn-analytics-jkt`), not the full resource path format.

## Troubleshooting

### API Not Configured

If you see "Rabbit API not configured", check:
- `RABBIT_API_KEY` or `BQ_OPTIMIZER_API_KEY` is set
- API key is valid

### jq Not Found

Install jq:
```bash
# macOS
brew install jq

# Linux
sudo apt-get install jq
# or
sudo yum install jq
```

### Query Extraction Failed

If you see "Could not extract query for optimization":
- Ensure the query is provided as an argument or via stdin
- Check that flags are properly formatted

### Fallback Behavior

If the optimized query fails, the function automatically retries with the original configuration. Check logs to see what happened.

## Integration with Existing Scripts

To replace `bq query` in existing scripts:

1. Source the function at the top of your script:
```bash
source /path/to/rabbit_bq.sh
```

2. Replace `bq query` with `rabbit-bq query`:
```bash
# Old
bq query -q -n 0 --replace --destination_table my_table "SELECT ..."

# New
rabbit-bq query -q -n 0 --replace --destination_table my_table "SELECT ..."
```

## API Response Structure

The Rabbit API returns:
- `optimizedJob.configuration.query.reservation`: Reservation ID if recommended
- `optimizedJob.configuration.labels`: Labels to add (e.g., `rabbit-job-optimization-id`)
- `optimizationResults[].performed`: Whether optimization was applied

## Limitations

- Currently only supports the `query` command
- Requires `jq` for JSON processing
- API timeout is 10 seconds (configurable in code)
- Reservation ID format must be compatible with `bq` CLI

## Support
For support, contact success@followrabbit.ai


