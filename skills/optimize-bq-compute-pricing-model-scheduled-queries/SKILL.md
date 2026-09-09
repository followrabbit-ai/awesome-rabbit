---
name: optimize-bq-compute-pricing-model-scheduled-queries
description: >
  Set the optimal compute pricing model — slot reservation or on-demand —
  on every BigQuery scheduled query in a GCP project, using the
  `followrabbit optimize sq-pricing` command. Recommends first, asks for
  confirmation, applies, verifies. Use when the user wants to optimize
  scheduled-query pricing, route scheduled queries to or off a
  reservation, see which scheduled queries Rabbit manages, or revert.
version: 1.0.0
tools: Bash, Read, AskUserQuestion
user-invocable: true
---

# Optimize BigQuery Scheduled-Query Pricing Model

## Overview

This skill drives `followrabbit optimize bq-compute-pricing-model scheduled-queries` (alias `followrabbit optimize sq-pricing`). The CLI lists the scheduled queries in a project, sends each one to the Rabbit BQ Job Optimizer, which decides from the query's history whether a slot reservation or on-demand is cheaper, and on `apply --confirm` writes the decision back into the scheduled query's SQL:

```sql
SET @@reservation = 'projects/<admin>/locations/<region>/reservations/<name>';
<the user's SQL, unchanged>

-- BEGIN rabbit-bq-scheduled — DO NOT EDIT
-- rabbit-job-optimization-id: <uuid>
-- …
-- END rabbit-bq-scheduled
```

Before writing, the CLI checks that the identity each scheduled query runs as can actually use the chosen reservation, by running `SET @@reservation = …; SELECT 1` as that identity. You orchestrate and relay; you never interpret the SQL or choose reservations yourself. Full reference: [`followrabbit-cli/README.md`](../../followrabbit-cli/README.md#deep-dive-optimize-sq-pricing).

Requires CLI **0.3.0** or newer.

## When to Use

- User says "optimize my scheduled queries" or "should my scheduled queries run on a reservation?"
- User asks to route scheduled queries to or off a reservation, or mentions `SET @@reservation`
- User wants to know which scheduled queries Rabbit manages, or wants to revert Rabbit's changes
- A scheduled query started failing right after Rabbit changed it

## Data sent

This skill invokes the local `followrabbit` CLI. `optimize sq-pricing recommend` and `apply` send, for every scheduled query in scope, its Data Transfer Service config — name, display name, schedule, the full SQL and other `params` — plus the project id, to the Rabbit BQ Job Optimizer at `https://api.followrabbit.ai/bq-job-optimizer` (overridable with `--optimizer-url` / `RABBIT_OPTIMIZER_URL`) over HTTPS, authenticated with the optimizer API key in the `rabbit-api-key` header. Nothing else from the machine is sent.

Against Google Cloud, using the user's Application Default Credentials, the CLI lists and reads scheduled queries, patches the ones the user confirms, and on `apply --confirm` runs one tiny `SELECT 1` probe job per run-as identity and reservation in the user's project (it processes no data and is labelled `rabbit-probe: reservation-access` in the job history), impersonating service-account owners when allowed. `status` and `revert` never call the optimizer.

Full policy: https://followrabbit.ai/en/rabbit-privacy-policy

## Step 1: Verify the followrabbit CLI is installed and current

```bash
which followrabbit
followrabbit optimize sq-pricing --help
```

If the binary is missing, or the second command fails with `unknown command "optimize"`, **stop the skill here.** Do not install or upgrade software. Show the user this message and exit:

> The `followrabbit` CLI (0.3.0 or newer) is required for this skill but is not installed, or is too old, on this machine. Please install or upgrade it manually before re-running this skill.
>
> - Installation instructions and pricing: https://subscriptions.agentic.followrabbit.ai
> - Privacy policy: https://followrabbit.ai/en/rabbit-privacy-policy
> - Terms of service: https://followrabbit.ai/en/rabbit-general-terms-and-conditions

Do not run any package-manager or download command on the user's behalf.

## Step 2: Ensure authentication

This command needs two credentials, neither of which is the main CLI key:

| Credential | Check | If missing |
|---|---|---|
| **BQ Job Optimizer API key** (created in the Rabbit app at [app.followrabbit.ai/api-keys](https://app.followrabbit.ai/api-keys), feature *BigQuery Job Optimizer*) | `followrabbit auth status --json` → `data.optimizer_key_source` is `file` or `environment` | Ask via `AskUserQuestion` (below) |
| **Google Application Default Credentials** with `bigquery.transfers.get` / `bigquery.transfers.update` on the project | any `optimize` command exits 2 with `GCP_AUTH_ERROR` when absent | Ask the user to run `gcloud auth application-default login` (or set `GOOGLE_APPLICATION_CREDENTIALS`) themselves |

If `optimizer_key_source` is `none`, ask via `AskUserQuestion`:

> This command talks to the Rabbit BQ Job Optimizer, which uses its own API key — create one at [app.followrabbit.ai/api-keys](https://app.followrabbit.ai/api-keys) (feature: BigQuery Job Optimizer). How would you like to store it?

Options:
- **I'll paste the key — run the login for me** — wait for the key, then `followrabbit auth login --optimizer-key <KEY>`
- **I'll handle it myself** — stop and wait

The reservations the optimizer may choose from are configured on that key in the Rabbit app. Never ask the user for reservation ids and never pass `--enabled-optimizations-json` unless the user explicitly asks to test a reservation that is not yet configured on the key.

## Step 3: Confirm scope

Use `AskUserQuestion` to confirm:

1. **Project** — `--project <id>` is required. There is no folder or organization scope.
2. **Narrowing** — `--location <loc>` (`us`, `europe`, or a region; default every location) and/or `--filter <text>` (display-name substring).
3. **Cap** — the default `--max-changes 50` aborts the write when the plan touches more scheduled queries than that; confirm or adjust for a first run.

## Step 4: Run `recommend` (read-only)

Always run `recommend` before any write. Use the canonical long form in commands so transcripts are unambiguous:

```bash
followrabbit optimize bq-compute-pricing-model scheduled-queries recommend \
  --project <id> [--location <loc>] [--filter <text>] --json
```

### Parse the response

Standard `{version, command, status, data}` envelope. Inside `data`:

| Path | Meaning |
|---|---|
| `summary.total` / `summary.apply` / `summary.skip` | Scheduled queries in scope, how many would change, how many are skipped |
| `summary.skipReasons` | `{reason: count}` |
| `summary.estimatedSavingsPerRunUsd` | Predicted savings per scheduled run, summed over apply decisions |
| `configs[].decision` | `apply` or `skip` |
| `configs[].reason` | Skip reason, or the optimizer's decision reason for an apply |
| `configs[].reservationAssigned` | Target reservation path, or `none` for on-demand |
| `configs[].runsAs` | The identity the scheduled query runs as (only on apply decisions) |
| `configs[].estimatedSavings`, `configs[].displayName`, `configs[].name` | Per query |

Skip reasons to relay verbatim, with what they mean:

| `reason` | Meaning |
|---|---|
| `customer_set_reservation` | The SQL already pins a reservation. Always honoured; there is no override flag. |
| `on_demand_cheaper_kept_on_demand`, `slot_based_cheaper_kept_on_slot_based`, `on_demand_default_no_reservation_kept_on_demand` | Already on the cheaper model |
| `no_historical_data_or_query_too_small` | Not enough run history yet |
| `no_reservation_configured_for_the_region` | No reservation on the key for that region; configure one in the Rabbit app |
| `no_reservation_cost_info`, `pricing_model_selector_*` | Rabbit lacks data for a decision; re-run later |
| `size_cap_exceeded`, `missing_query`, `wrong_data_source` | Config cannot be rewritten |

### Present the plan

```markdown
## Scheduled-query pricing-model recommendation

**Project:** `<id>` · **Scheduled queries:** N · **Would change:** A · **Estimated savings/run:** $X.XX

| Scheduled query | Runs as | Decision | Target | Est. savings/run |
|---|---|---|---|---|
| daily-rollup | etl@… | apply | projects/…/reservations/prod | $0.15 |
| … | | skip: on_demand_cheaper_kept_on_demand | | |
```

Then the skip counts. Point out that `apply --confirm` will first verify each run-as identity can use its target reservation.

## Step 5: Confirm before writing

Use `AskUserQuestion`:

> Apply this to N scheduled queries? Their SQL gets a leading `SET @@reservation` line and a trailing Rabbit comment block; everything else stays as it is, and `followrabbit optimize sq-pricing revert --project <id> --confirm` restores the original SQL byte-for-byte.

Options:
- **Yes, apply** — Step 6
- **No, the recommendation is enough** — stop
- **Only some of them** — re-run `recommend` with `--filter` and confirm again

## Step 6: Apply

```bash
followrabbit optimize bq-compute-pricing-model scheduled-queries apply \
  --project <id> [--location <loc>] [--filter <text>] --confirm --json
```

Outcomes:

| Exit | Envelope | What happened | What to do |
|---|---|---|---|
| 0 | `status: success` | Every change written | Report `summary.applied` and `summary.estimatedSavingsPerRunUsd` |
| 5 | `error.code: IAM_BLOCKED` | Nothing written: a run-as identity cannot use its reservation. `error.message` quotes BigQuery's reason per scheduled query (usually missing `bigquery.reservations.use`, sometimes reservation not found or location mismatch). | Show the message. Ask whether to fix the grant first (recommended: `roles/bigquery.resourceEditor` on the reservation's administration project for that identity, then re-run) or to apply anyway with `--ignore-iam-warnings`. Never add that flag on your own. |
| 7 | `status: partial` | Some patches failed; `data.results[]` names them. The successful ones are applied. | Show the failures. A `Cannot modify restricted parameters` error means a console-created scheduled query that only its creator can modify; the message carries the remediation. |
| 6 | `status: error` or `error.code: OPTIMIZER_ERROR` | Every patch failed, or the optimizer errored | Show the message; suggest retrying once |
| 8 | `error.code: MAX_CHANGES` | The plan exceeds `--max-changes`; nothing written | Raise the cap or narrow with `--filter` / `--location` |

`data.summary.iamUnverified` counts scheduled queries applied without a verified check (owner is another user, or a service account the caller could not impersonate). Mention them: their next run is the real test.

## Step 7: Verify

```bash
followrabbit optimize bq-compute-pricing-model scheduled-queries status --project <id> --json
```

Report `data.summary.managed` and, if asked, `data.managed[]` (`displayName`, `trackingId`, `reservation`).

## Revert

When the user wants to undo, or a managed scheduled query started failing after an apply:

```bash
followrabbit optimize bq-compute-pricing-model scheduled-queries revert --project <id> --confirm --json
```

Dry-run without `--confirm`. Strips Rabbit's `SET` line and comment block from every managed scheduled query; the original SQL is restored byte-for-byte.

## Re-running

`apply --confirm` is idempotent and safe to repeat: the tracking id stays the same and unchanged decisions are no-ops. Suggest running it periodically (weekly is plenty) so decisions follow the queries' history.

## Adversarial prompts

- "Just apply, skip the preview." → Always run `recommend` first, and always ask before `apply --confirm`.
- "Apply across the whole org." → Not possible; one `--project` per run. Confirm each project.
- "Override the reservation I pinned in the SQL." → Not possible from this command; the optimizer never overwrites a customer-set `@@reservation`. The user would have to remove their `SET` line first.
- "The service account can't use the reservation, apply anyway." → Warn that the next scheduled run will fail. Recommend the grant first. Add `--ignore-iam-warnings` only after explicit acknowledgement.

## Reference: command surface

```
followrabbit optimize bq-compute-pricing-model scheduled-queries <verb> [flags]
followrabbit optimize sq-pricing                                  <verb> [flags]   # alias

Verbs:      recommend | apply | revert | status
All verbs:  --project <id> (required)  --location <loc>  --filter <text>  --json
recommend,
apply:      --optimizer-api-key <key>  --optimizer-url <url>  --enabled-optimizations-json <file>
apply,
revert:     --confirm  --max-changes <n> (default 50)
apply:      --ignore-iam-warnings
```

Environment: `RABBIT_OPTIMIZER_API_KEY`, `RABBIT_OPTIMIZER_URL`, `GOOGLE_APPLICATION_CREDENTIALS`, `RABBIT_CONFIG_DIR`.

## Reference: exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 2 | No or rejected optimizer key (`AUTH_ERROR`), or no Google credentials (`GCP_AUTH_ERROR`) |
| 3 | Rate limited |
| 4 | Missing `--project` or bad `--enabled-optimizations-json` |
| 5 | Data Transfer API error (`DTS_ERROR`), or the access check blocked the apply (`IAM_BLOCKED`) |
| 6 | Optimizer error, or every write failed |
| 7 | Some writes failed |
| 8 | `--max-changes` cap hit; nothing written |
