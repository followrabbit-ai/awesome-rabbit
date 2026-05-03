# BigQuery Scheduled Query Pricing-Model Optimizer

Set the optimal pricing model — slot-reservation or on-demand — on every BigQuery scheduled query in a project (or a whole GCP folder), in one command.

The tool calls Rabbit's `bq-job-optimizer` service per query. The service uses your historical job stats and your tenant configuration (available reservations, current default pricing model per project) to decide whether each query should run on-demand or on a reservation. The CLI then patches each scheduled query's SQL with a fenced `SET @@reservation` statement so the next run honors the recommendation.

> **Status:** part of the `followrabbit` CLI. Installation, auth, and upgrade work the same as every other subcommand.

---

## What it does

For every scheduled query in scope:

1. **List** scheduled queries via the BigQuery Data Transfer Service API.
2. **Send** the full `TransferConfig` to the optimizer's `POST /v1/scheduled-query.optimize` endpoint.
3. **Receive** one of:
   - `decision: "apply"` — a fully-rewritten `optimizedConfig`. The CLI patches it back via `transferConfigs.patch update_mask=params`.
   - `decision: "skip"` — with a reason (`customer_set_reservation`, `no_recommendation_yet`, `wrong_data_source`, `size_cap_exceeded`, `missing_query`).
4. **Verify** the executing service account has `bigquery.reservationAssignments.use` on the recommended reservation. Block writes that would break the next execution unless `--ignore-iam-warnings` is passed.

What gets written into a managed scheduled query:

```sql
-- BEGIN rabbit-bq-scheduled (id: 7f3e…; ts: 2026-04-29T…; reason: slot_based_cheaper_assigned_to_reservation) DO NOT EDIT
SET @@reservation = 'projects/<admin>/locations/<region>/reservations/<name>';
-- END rabbit-bq-scheduled
<your original SQL — unchanged>
```

For "on-demand wins": `SET @@reservation = 'none';` instead.

The fence comment carries everything Rabbit needs to track the config across runs — a stable UUID (`id: …`), the timestamp of the last decision (`ts: …`), and the optimizer's reason string (`reason: …`). BQ Data Transfer Service `TransferConfig` resources don't have a `labels` field, so the fence is the single source of truth; there are no separate labels to clean up. The CLI re-runs detect "already managed" by parsing the existing fence's UUID out of the SQL.

---

## Install

The CLI is the same `followrabbit` Go binary used for `cost-review` and the other Rabbit tools.

```bash
# Homebrew (macOS, recommended)
brew install followrabbit-ai/tap/followrabbit

# npm (cross-platform)
npm install -g @followrabbit/cli

# Shell installer (everywhere else)
curl -fsSL https://followrabbit-ai.github.io/homebrew-tap/install.sh | sh
```

Verify:

```bash
followrabbit version --json
```

---

## Authenticate

You need a Rabbit API key — get one at [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai).

```bash
followrabbit auth login --key <YOUR_API_KEY>
followrabbit auth status --json
```

Your **available reservations** and **default pricing model per project** are stored in your Rabbit tenant configuration (keyed off the API key). The CLI does not pass them; the optimizer service resolves them server-side per request. If your tenant has no reservations configured yet, the CLI exits with a clear message pointing you back to the dashboard.

---

## GCP IAM

The credentials the CLI runs under (Application Default Credentials — `gcloud auth application-default login` for local use, or a service account in CI) need the following on every project in scope:

| Permission | Why |
|---|---|
| `bigquery.transfers.get` | List + read scheduled queries. |
| `bigquery.transfers.update` | Patch the optimized config back. |
| `resourcemanager.projects.list` | Folder-scope enumeration only. Skip when you only use `--project`. |

For each scheduled query the optimizer recommends moving onto a reservation, the **scheduled query's own service account** (the one that owns the config) needs `bigquery.reservationAssignments.use` on the target reservation. The CLI runs `testIamPermissions` post-recommendation and warns/blocks if any are missing — without that permission the scheduled query would fail at execution time.

---

## Usage

The canonical command path is hierarchical so the same shape generalizes to other optimizations and resources:

```
followrabbit <action> <optimization-domain> <target-resource> <verb> [flags]
```

For BigQuery scheduled query pricing-model optimization in v1:

```
followrabbit optimize bq-compute-pricing-model scheduled-queries <verb> [flags]
```

A short alias resolves to the same command:

```
followrabbit optimize sq-pricing <verb> [flags]
```

Use the alias day-to-day; use the long form in scripts for unambiguous transcripts.

### Verbs

| Verb | What it does | Writes? |
|---|---|---|
| `recommend` | Lists configs in scope, asks the optimizer for each, prints the plan. Read-only. | No |
| `apply` | Same as `recommend` but also patches the recommended changes. **Defaults to dry-run** — pass `--confirm` to actually write. | Yes (with `--confirm`) |
| `revert` | Strips the Rabbit fence from configs we manage. The original SQL beneath the fence is preserved byte-for-byte. | Yes (with `--confirm`) |
| `status` | Lists scheduled queries that are currently Rabbit-managed (detected by scanning for the fence header in the SQL). | No |

### Common flags

```
  --project <id>             OR --folder <id>             (one required)
  --location <region>        OR --all-locations            (default: --all-locations)
  --filter <substring>                                     Match scheduled-query display name
  --concurrency <n>                                        Default 8

  --dry-run / --confirm                                    apply: dry-run by default; --confirm to write
  --max-changes <n>                                        Safety cap; default 50
  (TF-managed detection reserved for v1.x — DTS has no Terraform label signal)
  --ignore-customer-reservation                            Override customer-set @@reservation skip (off by default)
  --ignore-iam-warnings                                    Apply even when the scheduled query SA lacks reservation `use` (off by default)

  --json                                                   Auto when stdout not a TTY
  --explain                                                Emit a markdown summary alongside JSON
  --quiet
  --api-key <key>  /  --api-url <url>                      Override Rabbit API auth
```

### Exit codes

Stable so agents and CI pipelines can branch without parsing output:

| Code | Meaning |
|---|---|
| `0` | OK |
| `2` | Auth failed (or your tenant has no reservations configured — see message) |
| `3` | Quota exceeded |
| `4` | Invalid input |
| `5` | IAM preflight failed (runner perms or scheduled-query-SA reservation `use`) |
| `6` | Network/server error |
| `7` | Partial — some configs failed; run state written for `--resume` |
| `8` | Safety cap (`--max-changes`) hit before any write |

---

## Examples

### See what would change in one project

```bash
followrabbit optimize sq-pricing recommend --project my-prod-project --json
```

Sample output (truncated):

```json
{
  "version": "1",
  "command": "optimize.bq-compute-pricing-model.scheduled-queries.recommend",
  "status": "success",
  "data": {
    "scope": { "project": "my-prod-project", "location": "all" },
    "summary": {
      "total": 47,
      "apply": 32,
      "skip_customer_set_reservation": 1,
      "skip_no_recommendation_yet": 13,
      "skip_size_cap_exceeded": 0,
      "skip_wrong_data_source": 1,
      "estimated_savings_per_run_usd": 18.42
    },
    "configs": [
      {
        "name": "projects/my-prod-project/locations/US/transferConfigs/abc",
        "displayName": "nightly-rollup",
        "decision": "apply",
        "reason": "applied",
        "context": {
          "reservationAssigned": "projects/admin/locations/US/reservations/prod-pool",
          "originalReservationId": "",
          "defaultPricingMode": "on_demand",
          "estimatedSavings": 1.10,
          "trackingId": "7f3e…"
        }
      }
    ]
  }
}
```

### Apply (with the dry-run-then-confirm safety pattern)

```bash
# 1. Plan
followrabbit optimize sq-pricing apply --project my-prod-project

# 2. Confirm
followrabbit optimize sq-pricing apply --project my-prod-project --confirm
```

`apply` without `--confirm` is identical to `recommend` plus a dry-run preview. Nothing is written.

### Apply across a whole folder

```bash
followrabbit optimize sq-pricing apply --folder 123456789012 --confirm
```

The optimizer service resolves each project's available reservations and current default pricing model from your tenant configuration — you don't need to specify them per project.

### Show what's already Rabbit-managed

```bash
followrabbit optimize sq-pricing status --project my-prod-project --json
```

### Revert everything we've ever applied in a project

```bash
followrabbit optimize sq-pricing revert --project my-prod-project --confirm
```

This strips every Rabbit fence from configs that carry our fence header in the SQL. The original SQL — everything below the fence — is left byte-for-byte unchanged.

### Run on a schedule

Recommendations are non-stationary: a query's optimal pricing model can flip month-to-month as your slot commitment, query patterns, and the optimizer's cost model evolve. Re-running on a schedule keeps things current. Cloud Scheduler example:

```hcl
resource "google_cloud_scheduler_job" "rabbit_sq_pricing" {
  name     = "rabbit-sq-pricing-weekly"
  schedule = "0 2 * * MON"

  http_target {
    uri         = "https://my-runner.example.com/run"
    http_method = "POST"
    body        = base64encode(jsonencode({
      command = "followrabbit optimize bq-compute-pricing-model scheduled-queries apply --folder ${var.folder_id} --confirm --json"
    }))
  }
}
```

In CI, run `recommend` (read-only, low blast radius) on every PR and `apply --confirm` on a separate cadence.

---

## Skip reasons in detail

When the recommendation is `decision: "skip"`, the `reason` field tells you why:

| Reason | What it means | What to do |
|---|---|---|
| `wrong_data_source` | Not a `scheduled_query` DTS config (e.g. cross-region copy). | Nothing — the CLI filters these during list, but the API guards defensively. |
| `missing_query` | `params.query` absent or not a string. Malformed config. | Inspect the config; this should never happen for scheduled queries created via the BQ console. |
| `customer_set_reservation` | The SQL already contains a `SET @@reservation` statement outside our fence. | The CLI assumes this is intentional. If you want the optimizer to manage it instead, remove the existing `SET @@reservation` and re-run, or pass `--ignore-customer-reservation`. |
| `no_recommendation_yet` | The optimizer has no actionable recommendation for this query yet — no historical data, query is too small to matter, or the project's current default already wins. | Re-run after a few days/weeks; the optimizer needs run history to make a confident recommendation. |
| `size_cap_exceeded` | The rewritten SQL would exceed the BQ DTS 1MB cap. | Slim down the query body, or accept that this scheduled query stays unmanaged. |

---

## Idempotency

`apply --confirm` is fully idempotent. On re-run:

1. The CLI sends each `TransferConfig` (which already carries our fence in the SQL).
2. The optimizer detects its own fence by parsing the fence header out of the SQL — the stable UUID is encoded in the `id: <UUID>` portion of the BEGIN marker.
3. It strips the existing fence, re-runs the decision, and re-emits the fence with the **same UUID** but possibly an updated reservation path.
4. If nothing changed, the patch is a no-op.

The UUID on a config never changes for the lifetime of that scheduled query. That stability is what lets Rabbit's analytics correlate "we recommended X, the actual job ran on Y, savings realized was $Z" across runs.

---

## Safety

- **Default to dry-run.** `apply` without `--confirm` shows the full plan and writes nothing.
- **Per-config diff.** Dry-run output includes the SQL diff for every config we'd modify.
- **`--max-changes <n>` cap** (default 50). Refuses to apply a plan with more changes than the cap unless the cap is raised explicitly. Lets you canary a small batch before unleashing the tool on a 5,000-config folder.
- **Customer-set `@@reservation` is sacred** by default. The optimizer refuses to overwrite a `SET @@reservation` outside our fence, even if it would be a better recommendation. Override only when you mean it.
- **Terraform-managed configs are skipped** by default. Letting the CLI rewrite a Terraform-provisioned config silently breaks the next `terraform apply` cycle.
- **IAM preflight on the recommended reservation.** If the scheduled query's SA can't `use` the reservation the optimizer chose, the next execution fails at runtime — the CLI catches this in advance and refuses to write the config (override with `--ignore-iam-warnings`).
- **`revert` is a real undo.** Strips Rabbit fences; leaves the original user SQL byte-for-byte unchanged.

---

## Troubleshooting

**`exit 2 — your Rabbit account has no reservations configured`**
Visit [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai), open your tenant, and add the reservations the optimizer should consider. Re-run.

**`exit 5 — bigquery.transfers.update not granted`**
The credentials the CLI is running under don't have permission to patch transfer configs. Add `roles/bigquery.admin` (or a custom role with `bigquery.transfers.{get,update}`) to the principal on the projects in scope.

**`exit 5 — scheduled query SA missing bigquery.reservationAssignments.use on <reservation>`**
The DTS service account that owns the scheduled query (visible in `bq show --transfer_config`) needs `bigquery.reservationAssignments.use` on the target reservation. Grant it on the reservation's admin project. Once granted, re-run `apply --confirm`.

**`exit 7 — partial`**
Some configs failed to patch. The CLI wrote a run-state file at `~/.cache/followrabbit/optimize/bq-compute-pricing-model/scheduled-queries/run-<id>.json` listing the failures. Re-run with `--resume <id>` to retry only the failed ones.

**Scheduled query started failing the morning after `apply`**
Almost certainly an IAM gap on the executing SA — check that `bigquery.reservationAssignments.use` is granted on the reservation that's now in the `SET @@reservation` line. If unsure, run `revert --confirm` to roll back, fix the IAM, and re-`apply`.

---

## Related

- **`cost-review`** skill — covers infrastructure-as-code cost review (Terraform + ad-hoc SQL).
- **`bq-proxy`** — sits in front of BigQuery and applies the same optimizer to ad-hoc queries from Looker/dbt/Airflow at request time. Complementary to this tool, which handles the persistent scheduled-query case.
- **`bq-job-optimizer/bash`** — minimal bash wrapper around `bq query` for one-off optimization in scripts.
