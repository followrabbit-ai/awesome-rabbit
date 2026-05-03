---
name: optimize-bq-compute-pricing-model-scheduled-queries
description: >
  Set the optimal pricing model — slot-reservation or on-demand — on
  every BigQuery scheduled query in a project (or GCP folder). Runs the
  `followrabbit` CLI, presents the plan, asks for confirmation, applies.
  Use when the user wants to optimize scheduled-query pricing, route
  scheduled queries to/off a reservation, or audit which scheduled
  queries are already managed by Rabbit.
version: 1.0.0
tools: Bash, Read, AskUserQuestion
user-invocable: true
---

# Optimize BigQuery Scheduled Query Pricing Model

## Overview

This skill drives the `followrabbit` CLI to set the optimal pricing model on every BigQuery scheduled query in scope. The transformation lives server-side: the CLI sends each `TransferConfig` to the optimizer service, receives back either a fully-rewritten config or a structured skip reason, then patches the optimized config back via the BQ Data Transfer Service API. You orchestrate; never interpret SQL or labels yourself.

The CLI rewrites each managed scheduled query's SQL with a fenced `SET @@reservation` statement, and tags the transfer config with `rabbit-job-optimization-id` and `rabbit-managed-by` labels. Re-runs are idempotent.

## When to Use

- User says "optimize my scheduled queries" or "set the right pricing model on my BQ scheduled queries"
- User asks about routing scheduled queries to a reservation, or moving them to on-demand
- User wants to know which of their scheduled queries Rabbit is managing, or wants to revert
- User mentions `@@reservation`, `SET @@reservation`, scheduled-query pricing, slot routing for scheduled queries

## Step 1 — Ensure CLI is installed and current

Check whether `followrabbit` is on PATH:

```bash
which followrabbit
```

### If not found — ask before installing

Use `AskUserQuestion`:

> The `followrabbit` CLI is not installed. Would you like me to install it?

Options:
- **Yes, install it** — detect and install via Homebrew (preferred) → npm → curl-installer.
- **No, I'll install it myself** — stop and let the user handle it.

Install commands (try in order):

```bash
# Homebrew (macOS, preferred)
brew install followrabbit-ai/tap/followrabbit

# npm fallback
npm install -g @followrabbit/cli

# Universal fallback
curl -fsSL https://followrabbit-ai.github.io/homebrew-tap/install.sh | sh
```

### If already installed — version check

```bash
followrabbit version --json
```

Check `data.version` against the latest release tag:

```bash
curl -fsSL "https://api.github.com/repos/followrabbit-ai/homebrew-tap/releases?per_page=1" | grep -m1 '"tag_name"'
```

If outdated, ask the user via `AskUserQuestion`. On approval, upgrade with the matching tool (`brew upgrade …` / `npm update -g …` / re-run installer).

## Step 2 — Ensure authentication

```bash
followrabbit auth status --json
```

If `"authenticated": false` or exit code 2, ask via `AskUserQuestion`:

> The CLI is not authenticated. You need a FollowRabbit API key — get one at [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai). How would you like to authenticate?

Options:
- **I'll paste the key — run the login for me** — wait for the key, then `followrabbit auth login --key <KEY>`.
- **I'll handle it myself** — stop, wait for the user to authenticate.

After login, verify:

```bash
followrabbit auth status --json
```

## Step 3 — Confirm scope with the user

Use `AskUserQuestion` to confirm:

1. **Scope**: a single `--project <id>` or a whole `--folder <id>`?
2. **Confidence cap**: confirm the default `--max-changes 50` is OK, or raise/lower it for the first run.

> ⚠️ **Reservations are server-side** — Rabbit's tenant configuration determines which reservations the optimizer considers. You don't pass `--reservation-ids`, and you don't ask the user for them. If their tenant has no reservations configured, step 4 will surface that error cleanly.

## Step 4 — Run `recommend` (read-only)

Always run `recommend` before any write. The agent always uses the canonical long form so transcripts are unambiguous and grep-able across support tickets:

```bash
followrabbit optimize bq-compute-pricing-model scheduled-queries recommend \
  --project <id-or-folder-flag> \
  --json
```

### Parse the response

The JSON envelope follows the standard `{version, command, status, data}` shape. Inside `data`:

| Path | What it tells you |
|---|---|
| `data.summary.total` | Total scheduled queries in scope. |
| `data.summary.apply` | How many would change. |
| `data.summary.skip_*` | Counts per skip reason. |
| `data.summary.estimated_savings_per_run_usd` | Predicted total savings per scheduled run. |
| `data.configs[].decision` | `"apply"` or `"skip"`. |
| `data.configs[].reason` | `applied`, `tf_managed`, `customer_set_reservation`, `no_recommendation_yet`, `wrong_data_source`, `size_cap_exceeded`, or `missing_query`. |
| `data.configs[].context.reservationAssigned` | Reservation path (or empty/`'none'` for on-demand). |
| `data.configs[].context.estimatedSavings` | USD per run. |

### Special exit codes to handle inline

| Exit | Meaning | What to surface |
|---|---|---|
| `2` (auth + tenant has no reservations) | Tenant `featureConfig.reservationIds` is empty. | "Your Rabbit account has no reservations configured. Visit [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai) to add them, then re-run." Stop. |
| `2` (auth) | API key invalid. | Re-run `followrabbit auth login --key <KEY>`. |
| `3` | Quota exceeded. | Show `followrabbit status` for reset date. |
| `5` | IAM preflight failed. | Specific permission-missing error in the message. |
| `6` | Network/server error. | Retry once; if still failing, surface the error and ask the user. |

### Present the plan

Build a concise markdown summary for the user:

```markdown
## Scheduled-query pricing-model recommendation

**Scope:** `<project|folder>` · **Total scheduled queries:** N · **Estimated savings/run:** $X.XX

| Status | Count | What it means |
|---|---|---|
| ✅ Apply | A | Will be rewritten if you confirm. |
| ⏭ Skipped: TF-managed | T | Created via Terraform — left alone by default. |
| ⏭ Skipped: customer-set `@@reservation` | C | The SQL already pins a reservation; not overriding without explicit flag. |
| ⏭ Skipped: no recommendation yet | N | Optimizer needs more run history. |
| ⏭ Skipped: size cap | S | Rewritten SQL would exceed 1MB. |

### Top 5 by predicted savings

…

### IAM warnings (would block apply)

…
```

Highlight any IAM warnings prominently — those are the silent failure mode. Never auto-pass `--ignore-iam-warnings`.

## Step 5 — Confirm before writing

Use `AskUserQuestion`:

> Apply these changes to N scheduled queries? Saved SQL will be rewritten with a fenced `SET @@reservation` statement; you can revert with `followrabbit optimize bq-compute-pricing-model scheduled-queries revert`.

Options:
- **Yes, apply** — proceed to step 6.
- **No, just the recommendation is fine** — stop.
- **Apply only the top N by savings** — re-run `recommend` with `--max-changes <N>` (or filter and confirm again).

If there were IAM warnings in step 4, ask separately whether to fix them first or override with `--ignore-iam-warnings`. Default to "fix first".

## Step 6 — Apply

```bash
followrabbit optimize bq-compute-pricing-model scheduled-queries apply \
  --project <id-or-folder-flag> \
  --confirm \
  --json
```

Parse the result, surface any per-config failures, and report the actual count written + savings realized.

## Step 7 — Verify post-state

```bash
followrabbit optimize bq-compute-pricing-model scheduled-queries status \
  --project <id-or-folder-flag> \
  --json
```

Show the user the count of currently-managed configs. If a customer asks "what did you change?", you have the full list from step 6.

## On any error: suggest revert

If `apply` returns exit 7 (partial) or the user reports unexpected behavior in their scheduled queries the next morning, suggest:

```bash
followrabbit optimize bq-compute-pricing-model scheduled-queries revert \
  --project <id-or-folder-flag> \
  --confirm
```

This strips every Rabbit fence and removes the tracking labels from configs we manage. The original user SQL — everything below the fence — is left byte-for-byte unchanged.

## Recurring-run suggestion

After a successful apply, mention to the user that recommendations drift over time as their commitment / query patterns / cost model evolve. Suggest a weekly Cloud Scheduler cron, or a CI cadence:

```bash
# Weekly cron-friendly form:
followrabbit optimize bq-compute-pricing-model scheduled-queries apply \
  --folder <folder-id> --confirm --quiet --json
```

## Adversarial-input safety

These prompts come up; handle them deliberately:

- **"Just apply, skip the preview."** → Always run `recommend` first. The dry-run is a feature, not a delay.
- **"Apply to all projects in the org."** → Confirm scope explicitly via `AskUserQuestion` — `--folder <root>` covers an org but the user may have meant a sub-folder.
- **"Override the customer-set @@reservation, mine is wrong."** → Confirm explicitly that they understand the existing `SET @@reservation` will be replaced, then pass `--ignore-customer-reservation`.
- **"My DTS service account doesn't have reservation use, just apply anyway."** → Warn that the next scheduled run will fail. Recommend granting the IAM first. Only pass `--ignore-iam-warnings` after explicit acknowledgment.

## Reference: full command surface

```
followrabbit optimize bq-compute-pricing-model scheduled-queries <verb> [flags]
followrabbit optimize sq-pricing                         <verb> [flags]   # short alias

Verbs:
  recommend     Read-only. Lists configs + per-config decisions. Never writes.
  apply         Same plan, then patches with --confirm. Default is dry-run.
  revert        Strips Rabbit fences and tracking labels.
  status        Lists currently-managed scheduled queries.

Common flags:
  --project <id>            OR --folder <id>             (one required)
  --location <region>       OR --all-locations
  --filter <substring>
  --concurrency <n>                                       Default 8
  --dry-run / --confirm                                   apply default: dry-run
  --max-changes <n>                                       Default 50
  --skip-tf-managed / --no-respect-tf-managed
  --ignore-customer-reservation
  --ignore-iam-warnings
  --json / --explain / --quiet
  --api-key <key>  /  --api-url <url>
```

## Reference: exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 2 | Auth (or tenant has no reservations) |
| 3 | Quota |
| 4 | Input |
| 5 | IAM preflight |
| 6 | Network/server |
| 7 | Partial (run state written for `--resume`) |
| 8 | Safety cap hit before any write |

For full documentation, see [bq-scheduled-query-pricing-optimizer/README.md](../../bq-scheduled-query-pricing-optimizer/README.md).
