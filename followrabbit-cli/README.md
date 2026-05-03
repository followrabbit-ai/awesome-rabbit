# `followrabbit` CLI Reference

Comprehensive reference for the `followrabbit` command-line tool — the single entrypoint for every Rabbit cost-optimization workflow that runs from a terminal or a CI pipeline.

This document covers install, auth, every command group, every exit code, and every global flag. For usage from inside an AI coding agent (Claude Code / Cursor / OpenAI Codex), see the [skills](../skills/) folder — the skills shell out to this CLI.

---

## Install

The CLI is a single static Go binary. Pick one:

```bash
# Homebrew (macOS, recommended)
brew install followrabbit-ai/tap/followrabbit

# npm (cross-platform)
npm install -g @followrabbit/cli

# Universal shell installer
curl -fsSL https://followrabbit-ai.github.io/homebrew-tap/install.sh | sh
```

Verify the install:

```bash
followrabbit version --json
```

Upgrade later with the matching tool: `brew upgrade followrabbit-ai/tap/followrabbit`, `npm update -g @followrabbit/cli`, or re-run the curl installer.

---

## Authenticate

You need a Rabbit API key. Get one at [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai).

```bash
followrabbit auth login --key <YOUR_API_KEY>
followrabbit auth status --json
```

`auth status` reports `authenticated: true` once the key is stored.

### `auth` subcommands

| Command | Purpose |
|---|---|
| `followrabbit auth login --key <KEY>` | Store an API key in the user config. |
| `followrabbit auth status --json` | Check whether the CLI is authenticated and (when not) print the signup URL. |
| `followrabbit auth logout` | Remove stored credentials. |
| `followrabbit auth token` | Print the current API key to stdout (for use in scripts that need to relay it elsewhere). |

---

## Global flags

These work with every command:

| Flag | Description |
|---|---|
| `--json` | Emit JSON wrapped in a `{version, command, status, data, error}` envelope. Auto-enabled when stdout is piped. |
| `--api-key <key>` | Override the stored API key for one invocation. |
| `--api-url <url>` | Override the API base URL (default: `https://api.agentic.followrabbit.ai`). |
| `--quiet` | Suppress non-essential output to stderr. |

## Environment variables

| Variable | Description |
|---|---|
| `FOLLOWRABBIT_API_KEY` | API key override (used instead of stored credentials). |
| `RABBIT_CONFIG_DIR` | Override the default config directory (`~/.config/followrabbit/`). |

## Exit codes

Stable across every command so CI pipelines and AI agents can branch without parsing output:

| Code | Meaning |
|---|---|
| `0` | OK |
| `2` | Auth — invalid/missing API key, or the call needs a tenant configuration step that hasn't been done yet (the message points to the dashboard). |
| `3` | Quota / rate limit. |
| `4` | Input — invalid flags or arguments. |
| `5` | Processing / IAM preflight. |
| `6` | Network or upstream server error. |
| `7` | Partial — some configs in a batch operation failed. The CLI prints which. |
| `8` | Safety cap (`--max-changes`) hit before any write. |

---

## Commands

### `version`

Print build, git, and runtime info.

```bash
followrabbit version
followrabbit version --json
```

### `status`

Show API key info, quota usage for the current period, and recent activity.

```bash
followrabbit status --json
```

### `costreview`

Scan local Terraform / SQL files and call the Rabbit API for AI-powered cost-optimization recommendations.

```bash
followrabbit costreview                          # scan ./*.tf in CWD
followrabbit costreview --types tf,sql --json    # scan TF + SQL, JSON output
followrabbit costreview --dir ./infrastructure   # scan a specific directory
```

| Flag | Default | Description |
|---|---|---|
| `--dir <path>` | CWD | Directory to scan. |
| `--types <list>` | `tf` | Comma-separated: `tf`, `sql`. |
| `--skills <list>` | `cost-impact,partition-check,best-practices` | Skill IDs. |
| `--model <name>` | API default | LLM override (e.g., `gemini-2.5-pro`). |

The response groups instructions by skill (`cost-impact`, `partition-check`, `best-practices`) — each is markdown that an agent or human can act on directly.

### `context`

Local-only structured TF/SQL scan. No API call — useful for piping into other tools.

```bash
followrabbit context --dir ./infrastructure --types tf,sql --json
```

Same `--dir` and `--types` flags as `costreview`.

### `recos list`

List saved cost-optimization recommendations for a repository.

```bash
followrabbit recos list                                 # auto-detect repo from git remote
followrabbit recos list --repo https://github.com/acme/infra
followrabbit recos list --type rightsizing --status open --json
```

| Flag | Description |
|---|---|
| `--repo <url>` | Repository URL (defaults to git remote). |
| `--type <filter>` | `rightsizing`, `idle_resource`, `commitment`. |
| `--status <filter>` | `open`, `applied`, `dismissed`. |

### `optimize bq-compute-pricing-model scheduled-queries`

Set the optimal compute pricing model — slot-reservation or on-demand — on every BigQuery scheduled query in a project. Hierarchical command path so the same shape generalizes to other optimization domains and target resources later (`optimize bq-storage-class tables`, `optimize gcs-storage-class buckets`, etc.). The full deep-dive lives [below](#deep-dive-optimize-bq-compute-pricing-model-scheduled-queries).

```bash
followrabbit optimize bq-compute-pricing-model scheduled-queries recommend --project <id>
followrabbit optimize sq-pricing recommend --project <id>     # short alias for the same command
```

### `completion <shell>`

Generate a shell-completion script.

```bash
followrabbit completion bash
followrabbit completion zsh
followrabbit completion fish
followrabbit completion powershell
```

Pipe into your shell's completion directory per its convention.

---

## Deep dive: `optimize bq-compute-pricing-model scheduled-queries`

This is the deep reference for the scheduled-query pricing optimizer. For a broader description of why and what, see the [README's Content section](../README.md#content).

### What it does

For every scheduled query in scope:

1. **List** scheduled queries via the BigQuery Data Transfer Service API.
2. **Send** the full `TransferConfig` to the optimizer's `POST /v1/scheduled-query.optimize` endpoint.
3. **Receive** one of:
   - `decision: "apply"` — a fully-rewritten `optimizedConfig`. The CLI patches it back via `transferConfigs.patch update_mask=params`.
   - `decision: "skip"` — with a reason (`customer_set_reservation`, `no_recommendation_yet`, `wrong_data_source`, `size_cap_exceeded`, `missing_query`).
4. **Verify** the executing service account has `bigquery.reservationAssignments.use` on the recommended reservation. Block writes that would break the next execution unless `--ignore-iam-warnings` is passed.

What gets written into a managed scheduled query:

```sql
SET @@reservation = 'projects/<admin>/locations/<region>/reservations/<name>';
<your original SQL — unchanged>

-- BEGIN rabbit-bq-scheduled — DO NOT EDIT
-- rabbit-job-optimization-id: 7f3e1234-5678-90ab-cdef-1234567890ab
-- rabbit-original-reservation-id: none
-- rabbit-optimized-reservation-id: projects/<admin>/locations/<region>/reservations/<name>
-- rabbit-decision-reason: slot_based_cheaper_assigned_to_reservation
-- rabbit-decision-ts: 2026-04-29T12:00:00.000Z
-- END rabbit-bq-scheduled
```

For "on-demand wins": `SET @@reservation = 'none';` and `rabbit-optimized-reservation-id: none`.

The trailing comment block carries everything Rabbit needs to track the config across runs — a stable UUID, the timestamp of the last decision, and the optimizer's reason. BQ Data Transfer Service `TransferConfig` resources don't have a `labels` field, so the fence comment is the single source of truth. Rabbit's pipeline joins `INFORMATION_SCHEMA.JOBS_BY_PROJECT.query` to optimizer decisions via `REGEXP_EXTRACT(query, r"-- rabbit-job-optimization-id: ([0-9a-f-]+)")`.

The leading `SET @@reservation` line is the only thing customers see at the top of their query in the BQ console; their SQL appears immediately under it. Tracking metadata sits at the end so it doesn't dominate the view.

### GCP IAM

The credentials the CLI runs under (Application Default Credentials — `gcloud auth application-default login` for local use, or a service account in CI) need:

| Permission | Why |
|---|---|
| `bigquery.transfers.get` | List + read scheduled queries. |
| `bigquery.transfers.update` | Patch the optimized config back. |

For each scheduled query the optimizer recommends moving onto a reservation, the **scheduled query's own service account** (visible in `bq show --transfer_config <id>`) needs `bigquery.reservationAssignments.use` on the target reservation. The CLI runs `testIamPermissions` post-recommendation and warns/blocks if any are missing — without that permission the scheduled query would fail at execution time.

### Verbs

| Verb | Purpose | Writes? |
|---|---|---|
| `recommend` | List configs in scope, ask the optimizer for each, print the plan. Read-only. | No |
| `apply` | Same plan, patches the recommended changes. **Defaults to dry-run** — pass `--confirm` to write. | Yes (with `--confirm`) |
| `revert` | Strips the Rabbit fence (leading `SET` + trailing block) from configs we manage. The original SQL beneath the fence is preserved byte-for-byte. | Yes (with `--confirm`) |
| `status` | Lists scheduled queries that are currently Rabbit-managed (detected by scanning for the trailing block in the SQL). | No |

### Common flags

```
--project <id>                           GCP project (required for v1; --folder support lands in v1.x)
--location <region>  / --all-locations    DTS region (default: --all-locations)
--filter <substring>                     Match scheduled-query display name (case-insensitive)
--concurrency <n>                        Default 8

--dry-run / --confirm                    apply: dry-run is default; --confirm to write
--max-changes <n>                        Safety cap; default 50
--ignore-customer-reservation            Override customer-set @@reservation skip (off by default)
--ignore-iam-warnings                    Apply even when the scheduled-query SA lacks reservation `use` (off by default)
(TF-managed detection reserved for v1.x — DTS has no Terraform label signal)

--json                                   Auto when stdout not a TTY
--explain                                Emit a markdown summary alongside JSON
--quiet
--api-key <key>  /  --api-url <url>      Override Rabbit API auth
--bq-optimizer-url <url>                 Override the bq-job-optimizer base URL
```

### Skip reasons

| Reason | What it means | What to do |
|---|---|---|
| `wrong_data_source` | Not a `scheduled_query` DTS config (e.g. cross-region copy). | Nothing — the CLI filters these during list, but the API guards defensively. |
| `missing_query` | `params.query` absent / not a string. Malformed config. | Inspect the config; this should not happen for scheduled queries created via the BQ console. |
| `customer_set_reservation` | The SQL already contains a `SET @@reservation` outside our fence. | The CLI assumes the customer set it intentionally. To override, remove the existing SET and re-run, or pass `--ignore-customer-reservation`. |
| `no_recommendation_yet` | The optimizer has no actionable recommendation — no historical data, query too small, or current default already wins. | Re-run after a few days/weeks; the optimizer needs run history. |
| `size_cap_exceeded` | The rewritten SQL would exceed the BQ DTS 1MB cap. | Slim down the query body, or accept this scheduled query stays unmanaged. |

### Examples

**Plan for one project (read-only):**

```bash
followrabbit optimize sq-pricing recommend --project my-prod-project --json
```

Sample summary:

```json
{
  "version": "1",
  "command": "optimize.bq-compute-pricing-model.scheduled-queries.recommend",
  "status": "success",
  "data": {
    "summary": {
      "total": 47,
      "apply": 32,
      "skip_customer_set_reservation": 1,
      "skip_no_recommendation_yet": 13,
      "skip_size_cap_exceeded": 0,
      "skip_wrong_data_source": 1,
      "estimated_savings_per_run_usd": 18.42
    }
  }
}
```

**Apply (dry-run-then-confirm):**

```bash
# Plan
followrabbit optimize sq-pricing apply --project my-prod-project

# Confirm
followrabbit optimize sq-pricing apply --project my-prod-project --confirm
```

**Show what's already Rabbit-managed:**

```bash
followrabbit optimize sq-pricing status --project my-prod-project --json
```

**Revert everything:**

```bash
followrabbit optimize sq-pricing revert --project my-prod-project --confirm
```

**Run on a schedule.** Recommendations drift over time. A weekly Cloud Scheduler:

```hcl
resource "google_cloud_scheduler_job" "rabbit_sq_pricing" {
  name     = "rabbit-sq-pricing-weekly"
  schedule = "0 2 * * MON"
  http_target {
    uri         = "https://my-runner.example.com/run"
    http_method = "POST"
    body        = base64encode(jsonencode({
      command = "followrabbit optimize bq-compute-pricing-model scheduled-queries apply --project ${var.project_id} --confirm --json"
    }))
  }
}
```

### Idempotency

`apply --confirm` is fully idempotent. On re-run:

1. The CLI sends each `TransferConfig` (which already carries our fence in the SQL).
2. The optimizer detects its own fence by parsing the trailing block — the stable UUID is encoded in the `rabbit-job-optimization-id` field.
3. It strips the existing fence, re-runs the decision, and re-emits the fence with the **same UUID**, possibly with an updated reservation path.
4. If nothing changed, the patch is a no-op.

The UUID on a config never changes for the lifetime of that scheduled query. That stability is what lets Rabbit's analytics correlate "we recommended X, the actual job ran on Y, savings realized was $Z" across runs.

### Troubleshooting

**`exit 2 — your Rabbit account has no reservations configured`**
Visit [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai), open your tenant, and add the reservations the optimizer should consider. Re-run.

**`exit 5 — bigquery.transfers.update not granted`**
The credentials the CLI is running under don't have permission to patch transfer configs. Add `roles/bigquery.admin` (or a custom role with `bigquery.transfers.{get,update}`) on the projects in scope.

**`exit 5 — scheduled query SA missing bigquery.reservationAssignments.use on <reservation>`**
The DTS service account that owns the scheduled query (visible in `bq show --transfer_config <id>`) needs `bigquery.reservationAssignments.use` on the target reservation. Grant it on the reservation's admin project, then re-run `apply --confirm`.

**Scheduled query started failing the morning after `apply`**
Almost certainly an IAM gap on the executing SA — check that `bigquery.reservationAssignments.use` is granted on the reservation now in the `SET @@reservation` line. If unsure, run `revert --confirm` to roll back, fix the IAM, and re-`apply`.

---

## Related

- [`cost-review`](../skills/cost-review/) skill — agent surface for `costreview` (Terraform + SQL cost analysis from inside an AI coding agent).
- [`optimize-bq-compute-pricing-model-scheduled-queries`](../skills/optimize-bq-compute-pricing-model-scheduled-queries/) skill — agent surface for the scheduled-query pricing optimizer (drives `recommend → confirm → apply → verify` end-to-end).
- [`bq-proxy`](../bq-proxy/) — sits in front of BigQuery and applies the same optimizer to ad-hoc queries from Looker/dbt/Airflow at request time. Complementary to `optimize bq-compute-pricing-model scheduled-queries`, which handles the persistent scheduled-query case.
