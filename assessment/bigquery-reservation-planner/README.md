# BigQuery Reservation Planner

A set of SQL queries to help you evaluate whether migrating BigQuery projects from on-demand pricing to slot-based reservations (Enterprise Edition) would reduce costs. The queries analyze the last 30 days of job history across your organization to identify savings opportunities and determine the right reservation size.

## Queries

### 1. Identify Projects to Move to Reservations

**File:** `project_to_move_to_reservations.sql`

Calculates the potential cost savings for each BigQuery project by comparing on-demand costs against what the equivalent workload would cost under slot-based reservations. Projects where the estimated savings exceed $50 are returned, ordered by total savings.

**Output columns:**
- `project_id` — The GCP project.
- `on_demand_cost` — Estimated on-demand cost over the last 30 days.
- `reservation_cost` — Estimated reservation cost for the same workload.
- `total_savings` — The difference (on-demand minus reservation).

### 2. Slot Usage Statistics for Max Slot Setting

**File:** `slot_usage_statistic_for_max_slot_setting.sql`

Computes slot usage statistics for the projects identified as reservation candidates. Use these statistics to determine the appropriate max slot setting for your reservation.

**Output columns:**
- `avg_slot_usage` — Average slot usage.
- `max_slot_usage` — Peak slot usage.
- `median_slot_usage` — 50th percentile.
- `percentile_90_slot_usage` — 90th percentile.
- `percentile_95_slot_usage` — 95th percentile.
- `percentile_99_slot_usage` — 99th percentile.

## Prerequisites

- **IAM role:** You must have at least the **BigQuery Resource Viewer** (`roles/bigquery.resourceViewer`) role at the organization level to query `INFORMATION_SCHEMA` across all projects.
- Both queries use the organization-level `INFORMATION_SCHEMA` views (`JOBS_BY_ORGANIZATION` and `JOBS_TIMELINE_BY_ORGANIZATION`).

## Usage

1. Replace the `${BQ_REGION}` parameter with the region you want to analyze (e.g., `us`, `eu`, `us-central1`).
2. Run each query separately **for every region** you use in BigQuery.
3. Start with `project_to_move_to_reservations.sql` to identify candidate projects, then run `slot_usage_statistic_for_max_slot_setting.sql` to size your reservation.

## Pricing Defaults

The queries use **US list prices** by default:

| Metric | Default Price |
|---|---|
| On-demand query pricing | $6.25 per TiB |
| Enterprise Edition slot pricing | $0.06 per slot-hour |

If your region has different pricing or you have a discounted price based on your Google contract, update the cost constants in both queries accordingly.

## Notes

- Both queries analyze the **last 30 days** of job history.
- Only `QUERY` type jobs are considered (non-query jobs are excluded).
- Jobs that already run under an existing reservation are excluded from the analysis.
- The reservation cost estimate applies a **0.7 utilization factor** to the slot-hour calculation, reflecting typical real-world efficiency.

## License

This module is licensed under the MIT License.
