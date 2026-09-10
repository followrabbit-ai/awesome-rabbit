# `followrabbit` CLI Reference

Reference for the `followrabbit` command-line tool — the entrypoint for Rabbit cost-optimization workflows that run from a terminal, a CI pipeline, or an AI coding agent.

Everything below was verified against the shipped binary **v0.3.0** by running the commands. For usage from inside an AI coding agent (Claude Code / Cursor / OpenAI Codex), see the [plugin section of the main README](../README.md#coding-agent-plugins) — the plugin skills shell out to this CLI.

---

## Install

The CLI is a single static Go binary. Pick one:

```bash
# Homebrew (macOS / Linux)
brew trust followrabbit-ai/tap        # required on Homebrew 6.x+
brew install followrabbit-ai/tap/followrabbit

# npm (cross-platform)
npm install -g @followrabbit/cli

# Universal shell installer
curl -fsSL https://followrabbit-ai.github.io/homebrew-tap/install.sh | sh
```

On Homebrew 6.x and later, `brew install` refuses formulae from untrusted third-party taps, so the `brew trust` step is required once per machine. In non-interactive CI, skipping it is a hard failure.

Verify the install:

```bash
followrabbit version
```

Upgrade later with the matching tool: `brew upgrade followrabbit-ai/tap/followrabbit`, `npm update -g @followrabbit/cli`, or re-run the curl installer.

---

## Authenticate

You need a Rabbit API key. Get one at [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai).

```bash
followrabbit auth login --key <YOUR_API_KEY>
followrabbit auth status
```

`auth status` reports `authenticated: true` once the key is stored. There is no browser-based login: `auth login` without `--key` exits 4 with `browser-based login is not yet supported; use --key to provide an API key`.

| Command | Purpose |
|---|---|
| `followrabbit auth login --key <KEY>` | Store an API key in the user config. |
| `followrabbit auth status` | Check whether the CLI is authenticated; prints the signup URL when not. |
| `followrabbit auth logout` | Remove stored credentials. |
| `followrabbit auth token` | Print the current API key to stdout, for scripts that need to relay it. |

Keys are stored at `~/.config/followrabbit/credentials.json` (mode `0600`) and travel only in the `X-Rabbit-Api-Key` request header.

### Second key for `optimize`

The `optimize` commands talk to a different service, the **Rabbit BQ Job Optimizer**, which has its own keys. Create one in the Rabbit app at [app.followrabbit.ai/api-keys](https://app.followrabbit.ai/api-keys) (feature: BigQuery Job Optimizer) and store it beside the main key:

```bash
followrabbit auth login --optimizer-key <YOUR_OPTIMIZER_KEY>
```

`auth status` reports where the optimizer key comes from (`optimizer_key_source`: `file`, `environment` or `none`). It is only read by `followrabbit optimize`; every other command ignores it. The reservations the optimizer may route scheduled queries to are configured on that key in the Rabbit app, not passed on the command line.

---

## Global flags

These work with every command:

| Flag | Description |
|---|---|
| `--json` | Emit JSON wrapped in a `{version, command, status, data, error}` envelope. **Auto-enabled whenever stdout is not a TTY** — anything piping or capturing CLI output gets JSON without asking for it. |
| `--api-key <key>` | Override the stored API key for one invocation. |
| `--api-url <url>` | Override the API base URL (default: `https://api.agentic.followrabbit.ai`). |
| `--quiet` | Suppress non-essential output. |

## Environment variables

| Variable | Description |
|---|---|
| `FOLLOWRABBIT_API_KEY` | API key override, used instead of stored credentials. Credential-bearing — treat like any secret in CI. |
| `RABBIT_API_URL` | API base URL override, same effect as `--api-url`. |
| `RABBIT_CONFIG_DIR` | Override the default config directory (`~/.config/followrabbit/`). |
| `RABBIT_OPTIMIZER_API_KEY` | BQ Job Optimizer key override for `optimize`, used instead of the stored one. Credential-bearing. |
| `RABBIT_OPTIMIZER_URL` | BQ Job Optimizer base URL override, same effect as `--optimizer-url`. |
| `GOOGLE_APPLICATION_CREDENTIALS` | Standard Google ADC override; `optimize` uses it for every GCP call. |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | OK |
| `2` | Auth — invalid or missing API key. |
| `3` | Quota exhausted / rate limited. |
| `4` | Input — invalid flags or arguments (also the no-browser-login case above). |
| `5` | Non-2xx response from the API. |
| `6` | Network error. |
| `7` | `sql --fail-on` threshold met — a finding at or above the given level exists. |
| `8` | `optimize`: the `--max-changes` cap was hit; nothing was written. |

`optimize` reuses `5`, `6` and `7` with its own meanings (GCP API error or IAM block, optimizer error or every write failed, some writes failed) — see [its exit codes](#exit-codes-1).

---

## Commands

### `version`

Print build and runtime info.

```bash
followrabbit version
```

### `status`

Show API key info and quota usage for the current period.

```bash
followrabbit status
```

### `costreview`

Scan local Terraform / SQL files and call the Rabbit API for AI-powered cost-optimization recommendations.

```bash
followrabbit costreview                          # scan Terraform in the current directory
followrabbit costreview --dir ./infra --types tf,sql
followrabbit costreview --filter sql --skills sql-antipatterns
```

| Flag | Default | Description |
|---|---|---|
| `--dir <path>` | current directory | Directory to scan. |
| `--types <list>` | `tf` | Comma-separated scan types: `tf`, `sql`. |
| `--filter <name>` | — | Convenience alias for `--types`: `sql`, `infra`, or `all`. Overrides `--types` when set. |
| `--skills <list>` | `cost-impact,partition-check,best-practices` | Skill IDs to run. **Replaces** the default set rather than adding to it — to add one, list the defaults too. |
| `--model <name>` | API default | LLM override (e.g. `gemini-2.5-pro`). |

The response groups instructions by skill — each is markdown that an agent or human can act on directly. See the [data-flow disclosure](../README.md#data-sent-to-the-followrabbit-api) for exactly what is uploaded.

### `context`

Local-only structured Terraform/SQL scan. No API call — useful for piping into other tools or giving an agent repo context.

```bash
followrabbit context --dir ./infra --types tf,sql --json
```

Same `--dir` and `--types` flags as `costreview`.

### `sql`

Deterministic BigQuery cost checks over the SQL you name — files, directories, stdin, or an inline query. No model call and no quota spend, so it is meant to run on every save or from a pre-commit hook. Requires **0.2.0** or newer; against an older CLI the command is unknown.

```bash
followrabbit sql query.sql                       # named file
followrabbit sql models/ transforms/             # directories, walked for *.sql and *.sqlx
cat q.sql | followrabbit sql                     # stdin
followrabbit sql -q "SELECT * FROM \`p.d.t\`"    # inline SQL
followrabbit sql models/ --fail-on high --json   # CI gate
```

| Flag | Description |
|---|---|
| `-q, --query <sql>` | Inline SQL instead of paths. |
| `--fail-on <level>` | Exit 7 when a finding at or above `high`, `medium`, or `low` exists. Without it, findings never fail the command. |
| `--all` | Print every finding instead of the first 20. |
| `--show-skipped` | List skipped files individually with their reason. |
| `--stdin-filename <name>` | Name to report for stdin or `--query` input. |

How inputs are treated:

- A file you name, stdin, and `--query` are checked as BigQuery by declaration — no dialect gate.
- A directory is walked for `*.sql` and `*.sqlx`. Each file found passes through a BigQuery dialect gate first; files it does not recognise are skipped with reason `not_bigquery`. Hidden directories and `target/`, `node_modules/`, `dbt_packages/`, `dbt_modules/`, `venv/`, `__pycache__/`, `build/`, `dist/` are not descended into. A directory you name is always read, so `followrabbit sql target/compiled/` works.
- Templates are not rendered. A file still carrying `{{`, `{%`, `${`, or `@{` is skipped with reason `unresolved_templating` — run `dbt compile` and point at `target/compiled/`.
- Other skip reasons: `parse_error`, `too_large` (over 128 KiB), `empty`. Skipped files are always counted in the summary; zero findings with skipped files is not a clean bill of health.
- Limits: 128 KiB per file, 500 files per run (more is exit 4 — narrow the paths).

Each finding carries the file, line span, level (`high` / `medium` / `low`), a message, an optional fix, and a `measure_first` flag meaning measure the impact before applying the fix.

**Data sent:** the contents and relative paths of the SQL files named, and nothing else from the repository. The SQL is analysed in memory and not stored. The server keeps one record per run — file and finding counts and the rule ids that fired — plus a keyed hash of each file path only when the API key belongs to a customer account; keys without one leave no path information.

### `recos list`

List saved cost-optimization recommendations for a repository.

```bash
followrabbit recos list                                 # repo auto-detected from git remote
followrabbit recos list --repo https://github.com/acme/infra
followrabbit recos list --type rightsizing --status open
```

| Flag | Description |
|---|---|
| `--repo <url>` | Repository URL (defaults to the git `origin` remote). |
| `--type <filter>` | `rightsizing`, `idle_resource`, `commitment`. |
| `--status <filter>` | `open`, `applied`, `dismissed`. |

### `optimize bq-compute-pricing-model scheduled-queries`

Set the optimal compute pricing model — slot reservation or on-demand — on every BigQuery scheduled query in a project, using the Rabbit BQ Job Optimizer. `optimize sq-pricing` is the short spelling of the same command. Requires **0.3.0** or newer.

```bash
followrabbit optimize sq-pricing recommend --project <id>            # read-only plan
followrabbit optimize sq-pricing apply --project <id>                # dry-run
followrabbit optimize sq-pricing apply --project <id> --confirm      # write
followrabbit optimize sq-pricing status --project <id>               # what Rabbit manages
followrabbit optimize sq-pricing revert --project <id> --confirm     # undo
```

Full reference: [Deep dive: `optimize sq-pricing`](#deep-dive-optimize-sq-pricing).

### `completion <shell>`

Generate a shell-completion script for `bash`, `zsh`, `fish`, or `powershell`.

```bash
followrabbit completion zsh
```

Run `followrabbit completion --help` for per-shell load instructions.

---

## Deep dive: `optimize sq-pricing`

Canonical name: `followrabbit optimize bq-compute-pricing-model scheduled-queries <verb>`. `optimize sq-pricing <verb>` is an alias; JSON output always reports the canonical name in `command`.

### What it does

A scheduled query is a persistent BigQuery Data Transfer Service config, so it never passes through the [reverse proxy](../bq-reverse-proxy/) and cannot be routed at submission time. This command applies the same optimizer decision to the stored config instead. For every scheduled query in scope:

1. **List** the scheduled queries in the project (every location, or `--location`).
2. **Send** each config to the optimizer, which decides from the query's history whether a slot reservation or on-demand is cheaper for it.
3. **Receive** either a rewritten config (`decision: apply`) or a skip reason.
4. On `apply --confirm`, **check** that the identity the scheduled query runs as can use the chosen reservation, **re-read** the config and, only if nobody changed it since the plan was computed, **patch** it back (`update_mask=params`; nothing else on it changes, including its owner). A scheduled query edited in the meantime is left alone and reported as failed with `changed since the plan was computed`; re-run to plan against the current version. `revert` applies the same guard.

What a managed scheduled query's SQL looks like afterwards:

```sql
SET @@reservation = 'projects/<admin>/locations/<region>/reservations/<name>';
<your original SQL — unchanged>

-- BEGIN rabbit-bq-scheduled — DO NOT EDIT
-- rabbit-job-optimization-id: 7f3e1234-5678-90ab-cdef-1234567890ab
-- rabbit-original-reservation-id: none
-- rabbit-optimized-reservation-id: projects/<admin>/locations/<region>/reservations/<name>
-- rabbit-decision-reason: slot_based_cheaper_assigned_to_reservation
-- rabbit-decision-ts: 2026-09-09T12:00:00.000Z
-- END rabbit-bq-scheduled
```

When on-demand wins the first line is `SET @@reservation = 'none';`. The leading line is what BigQuery acts on; the trailing block is how Rabbit tracks the decision (Data Transfer Service configs have no labels). Rabbit joins executed jobs to decisions through `INFORMATION_SCHEMA.JOBS_BY_PROJECT.query`, so the block must stay on the query for savings to be attributed.

### Prerequisites

| What | Why |
|---|---|
| Optimizer key stored (`auth login --optimizer-key`, or `RABBIT_OPTIMIZER_API_KEY`) | Authenticates the decision calls. Created at [app.followrabbit.ai/api-keys](https://app.followrabbit.ai/api-keys); the reservations to consider are configured on the key. |
| Google Application Default Credentials (`gcloud auth application-default login`, or `GOOGLE_APPLICATION_CREDENTIALS`) | Every GCP call. |
| `bigquery.transfers.get` and `bigquery.transfers.update` on the project (`roles/bigquery.admin` has both) | List and patch scheduled queries. |
| `roles/iam.serviceAccountTokenCreator` on each service account your scheduled queries run as | Lets the CLI test that account's reservation access before writing. Without it the check reports `unverified` and the apply still proceeds. |
| `bigquery.reservations.use` for each identity a scheduled query runs as, granted on the **reservation's administration project** (`roles/bigquery.resourceEditor` carries it) | What `SET @@reservation` needs at run time. Grant it on the project: in our tests a grant on the reservation resource alone passed IAM's `testIamPermissions` but BigQuery still refused the job. The query and the reservation must also be in the same organization and location. |

### Verbs

| Verb | Purpose | Writes? |
|---|---|---|
| `recommend` | List the scheduled queries in scope, ask the optimizer about each, print the plan. | No |
| `apply` | Same plan; **dry-run by default**, `--confirm` patches. Runs the reservation access check first. | With `--confirm` |
| `revert` | Strip the leading `SET` and the trailing block from every scheduled query Rabbit manages, restoring the original SQL byte-for-byte. Dry-run by default. | With `--confirm` |
| `status` | List the scheduled queries that carry Rabbit's block, with tracking id and reservation. | No |

### Flags

| Flag | Verbs | Description |
|---|---|---|
| `--project <id>` | all | GCP project. Required. |
| `--location <loc>` | all | Only this location: `us`, `europe` (the EU multi-region, as the Data Transfer Service names it), or a region such as `europe-west3`. Default: every location the Data Transfer Service supports, scanned concurrently. |
| `--filter <text>` | all | Only scheduled queries whose display name contains this, case-insensitive. |
| `--confirm` | `apply`, `revert` | Write. Without it the command prints what it would do. |
| `--max-changes <n>` | `apply`, `revert` | Abort with exit 8 before writing anything when the plan touches more than `n` scheduled queries. Default 50. |
| `--ignore-iam-warnings` | `apply` | Write even when a run-as identity is known to lack `bigquery.reservations.use`. |
| `--optimizer-api-key <key>` | `recommend`, `apply` | One-off key override. |
| `--optimizer-url <url>` | `recommend`, `apply` | Optimizer base URL override (default `https://api.followrabbit.ai/bq-job-optimizer`). |
| `--enabled-optimizations-json <file>` | `recommend`, `apply` | JSON file with an `enabledOptimizations` array; overrides the reservations configured on the key for this run. For testing a reservation before configuring it on the key. |

### The reservation access check

The scheduled query does not run as you. It runs as its owner: the user who created it in the BigQuery console, or the service account it was created with. If that identity cannot use the reservation, the query fails at its next scheduled run, not now. So before writing, `apply --confirm` runs the smallest possible query, `SET @@reservation = '<target>'; SELECT 1`, in the scheduled query's project and location **as that identity**. It is a real query (BigQuery's dry run does not validate reservations), it processes no data, it runs once per distinct identity and reservation rather than once per scheduled query, and it shows up in the project's job history labelled `rabbit-probe: reservation-access`. The `--max-changes` cap is checked before any probe runs.

| Run-as identity | How it is tested | Result |
|---|---|---|
| A service account | The CLI impersonates it (needs `roles/iam.serviceAccountTokenCreator` on it). | `ok` / `missing`, or `unverified` when impersonation is not allowed. |
| The identity your ADC resolve to (a user, or the service account the CLI itself runs as) | Your own credentials. | `ok` / `missing`. |
| Another user | Cannot be tested from here. | `unverified`. |

`missing` carries BigQuery's own reason (no `bigquery.reservations.use`, reservation not found, location mismatch, no `bigquery.jobs.create`), and on any scheduled query it blocks the whole apply (exit 5, `IAM_BLOCKED`, nothing written) unless `--ignore-iam-warnings` is passed. `unverified` is reported in the plan (`iam.status`, `summary.iamUnverified`) and does not block. `recommend` and dry-run `apply` skip the check.

### Skip reasons

| `reason` | Meaning | What to do |
|---|---|---|
| `customer_set_reservation` | The SQL already contains a `SET @@reservation` that Rabbit did not write. | Always honoured; there is no override. Remove the statement to let the optimizer decide. |
| `on_demand_cheaper_kept_on_demand`, `slot_based_cheaper_kept_on_slot_based`, `on_demand_default_no_reservation_kept_on_demand` | The current pricing model is already the cheaper one for this query. | Nothing. Re-run later; history changes. |
| `no_historical_data_or_query_too_small` | Not enough run history for a decision, or the query is too small to matter. | Re-run after the query has run a few times. |
| `no_reservation_configured_for_the_region` | No reservation on the key for the query's region. | Add one on the key at [app.followrabbit.ai/api-keys](https://app.followrabbit.ai/api-keys). |
| `no_reservation_cost_info` | A reservation exists but Rabbit has no cost data for it yet. | Wait for the next data load. |
| `pricing_model_selector_*` | The no-history fallback model declined (uncertain, region unresolved, service unreachable). | Nothing; re-run later. |
| `size_cap_exceeded` | The rewritten SQL would exceed the 1 MB limit on scheduled queries. | Shorten the query, or leave it unmanaged. |
| `missing_query`, `wrong_data_source` | Malformed config. Should not occur for console-created scheduled queries. | Inspect the config. |

### Output

`recommend` and dry-run `apply` (`data`):

```json
{
  "dryRun": true,
  "summary": { "total": 6, "apply": 3, "skip": 3,
               "skipReasons": { "customer_set_reservation": 1, "on_demand_cheaper_kept_on_demand": 2 },
               "estimatedSavingsPerRunUsd": 0.45 },
  "configs": [
    { "name": "projects/123/locations/us/transferConfigs/6aa1…", "displayName": "daily-rollup",
      "runsAs": "etl@my-project.iam.gserviceaccount.com", "location": "us",
      "decision": "apply", "reason": "slot_based_cheaper_assigned_to_reservation",
      "reservationAssigned": "projects/admin/locations/us/reservations/prod",
      "defaultPricingMode": "on_demand", "estimatedSavings": 0.15,
      "trackingId": "45fd26c6-…" }
  ]
}
```

`apply --confirm` adds `iam: {status, detail}` to each apply decision and reports `summary: {applied, skipped, failed, iamMissing, iamUnverified, estimatedSavingsPerRunUsd}` plus `results[]` (`{name, status: applied|failed, error}`). `status` returns `summary: {total, managed}` and `managed[]` (`{name, displayName, trackingId, reservation}`). `revert` returns `toRevert[]` on dry-run and `{reverted, failures[]}` on `--confirm`.

After a write phase the envelope's top-level `status` is `success`, `partial` (some writes failed, exit 7) or `error` (every write failed, exit 6), so a caller can branch on it without reading the summary. Every other failure is the usual `status: "error"` envelope with `error.code` and `error.message`.

### Exit codes

| Code | Meaning |
|---|---|
| `2` | No or rejected optimizer key (`AUTH_ERROR`), or no Google credentials (`GCP_AUTH_ERROR`). |
| `4` | Missing `--project`, or a bad `--enabled-optimizations-json` file. |
| `5` | Data Transfer or Reservation API call failed (`DTS_ERROR`), or the access check blocked the apply (`IAM_BLOCKED`). |
| `6` | Optimizer unreachable or errored, or every write failed. |
| `7` | Some writes failed; `results[]` names them. The successful ones stay applied. |
| `8` | `--max-changes` cap hit; nothing written. |

### Idempotency

`apply --confirm` can be re-run at any time. The optimizer strips its own block, re-decides, and re-emits it with the **same tracking id**; if the decision is unchanged the patch is a no-op. The id stays with the scheduled query for its lifetime, which is what lets Rabbit attribute realised savings to the decision. Run it on a schedule (weekly is plenty) so decisions follow the query's history.

### Limitation: scheduled queries created in the console

A scheduled query created with **Schedule** in the BigQuery console runs as its creator, and only that user may change its SQL, whatever roles anyone else holds. Patching it as someone else fails:

```
Cannot modify restricted parameters without taking ownership of the transfer configuration.
```

The CLI appends the remediation to that error. Your options, in order of preference:

1. Run the CLI as the owner: `gcloud auth application-default login` as the account in `ownerInfo.email` (`bq show --transfer_config <name>`).
2. Move the scheduled query to a service account (`bq update --transfer_config --service_account_name=…`), after which anyone with `bigquery.transfers.update` can manage it. The service account must hold every permission the query needs.
3. Create new scheduled queries with a service account from the start.

Because each scheduled query is patched independently, an owner mismatch on one does not stop the others: the command exits 7 and lists the failures.

### Troubleshooting

**exit 2, `no optimizer API key`** — store one with `followrabbit auth login --optimizer-key <KEY>`, or set `RABBIT_OPTIMIZER_API_KEY`. The main CLI key does not work here.

**exit 2, `the optimizer rejected the API key`** — the key is not a BQ Job Optimizer key, or points at another environment. Create one at [app.followrabbit.ai/api-keys](https://app.followrabbit.ai/api-keys).

**exit 2, `no Google Application Default Credentials`** — run `gcloud auth application-default login`, or set `GOOGLE_APPLICATION_CREDENTIALS`.

**exit 5, `DTS_ERROR … 403`** — the ADC identity lacks `bigquery.transfers.get` / `bigquery.transfers.update` on the project.

**exit 5, `IAM_BLOCKED`** — the message quotes BigQuery's refusal for the run-as identity. Most often it lacks `bigquery.reservations.use`: grant `roles/bigquery.resourceEditor` on the reservation's administration project, wait a few minutes for IAM to propagate, re-run. `--ignore-iam-warnings` writes anyway; the scheduled query will fail at its next run until the grant lands.

**`iam.status: unverified`** — the CLI could not impersonate the run-as service account (grant yourself `roles/iam.serviceAccountTokenCreator` on it), or the owner is another user. Check that identity's access yourself before relying on the next run.

**exit 7, `Cannot modify restricted parameters`** — see the console limitation above.

**exit 7 or 6, `changed since the plan was computed`** — someone edited that scheduled query between the plan and the write, so the CLI did not touch it. Re-run; the new plan is computed against the current SQL.

**Every decision is `skip`** — usually `no_reservation_configured_for_the_region` (no reservation on the key) or `no_historical_data_or_query_too_small` (new queries). `recommend --json` shows `skipReasons` at a glance.

**A managed query started failing after `apply`** — almost always reservation access for its run-as identity. `revert --confirm` restores the original SQL immediately; fix the grant and apply again.

---

## Troubleshooting

**`AUTH_ERROR` / exit 2** — the stored key is missing or the server rejected it. Run `followrabbit auth status` to see which; re-login with `followrabbit auth login --key <KEY>`.

**Exit 3** — your key's quota for the period is exhausted or you are rate limited. Check usage with `followrabbit status`; quota is managed at [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai).

**`400 INVALID_REQUEST` from `costreview` on large repos** — the server caps uploaded context at 500,000 characters. SQL files are capped at 100 KiB each but there is no aggregate client-side cap, so a repo with roughly six or more large SQL files can exceed the ceiling. Narrow the scan with `--dir`, or split the review.

**`unknown command "sql"`** — the installed CLI predates 0.2.0. Upgrade with the matching tool (see [Install](#install)). If the CLI is current but reports `NOT_SUPPORTED` (exit 5), the `--api-url` you point at does not serve the command yet.

**Corporate proxy / TLS interception** — the CLI talks HTTPS to `api.agentic.followrabbit.ai`. If your proxy re-signs TLS, the request fails with a certificate error (exit 6); have the proxy's CA in the system trust store or allowlist the API host.

**Getting JSON when you expected text** — output is auto-JSON whenever stdout is piped or captured (see global flags). Run in a terminal, or embrace the JSON envelope in scripts.

---

## Related

- [Coding-agent plugins](../README.md#coding-agent-plugins) — the Claude Code / Cursor / Codex surface for this CLI.
- [`cost-review`](../skills/cost-review/) skill — the agent skill that drives `costreview`.
- [assessment-cli](../assessment-cli/) — pre-sales assessment of a GCP/BigQuery environment; separate Python tool, no API key needed.
- [bq-reverse-proxy](../bq-reverse-proxy/) — applies the same BQ Job Optimizer to ad-hoc jobs from Looker / dbt / Airflow at submission time; `optimize sq-pricing` covers the scheduled queries the proxy never sees.
