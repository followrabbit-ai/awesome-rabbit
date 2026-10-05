# awesome-rabbit

This repository aims to provide tools, scripts, and code snippets for current and potential Rabbit users. Whether you're just getting started or looking to enhance your experience, you'll find helpful resources here to support your journey with Rabbit.

# Content

- [assessment/bigquery-reservation-waste](assessment/bigquery-reservation-waste/):
  - SQL scripts for analyzing BigQuery reservation slot waste, helping you identify underutilized reservations and optimize costs.

- [assessment/bq-pricing-model-optimization](assessment/bq-pricing-model-optimization/):
  - SQL scripts for analyzing and optimizing BigQuery pricing models at both the project and organization level.

- [assessment-cli](assessment-cli/):
  - A Python command-line tool that assesses a GCP/BigQuery environment and quantifies cost-saving opportunities with Rabbit. Given an organization, folder, or project scope it enumerates accessible projects, runs project-scoped `INFORMATION_SCHEMA` queries across reservations, capacity commitments, job pricing-model and storage billing-model optimization, failed-job cost, and reservation waste, then writes per-category CSVs and a dual-currency Markdown savings report. Built for operators with project-level access only — anything it cannot read is skipped and reported, never fatal. Installs with plain `pip` (no poetry or uv).

- [gcs-insights-and-usage-logs](gcs-insights-and-usage-logs/):
  - Rabbit is capable of providing deep folder or object level insights and storage class recommendations with automated class management based on the access patterns. In order to do this, we need to enable Storage Insights and Usage Logs on the target buckets. This Terraform module is designed to configure Google Cloud Storage Insights and Usage Logs for specified target buckets. It automates the setup of necessary resources, including report buckets, IAM roles, and report configurations.

- [bq-backup-and-restore](bq-backup-and-restore/):
  - A command-line tool for creating and restoring backups of BigQuery datasets. Supports backing up all datasets in a project or specific datasets, with options for current state or point-in-time backups (last 7 days). Only backs up tables, excluding views, models, and other non-table objects.

- [bq-reverse-proxy](bq-reverse-proxy/):
  - The **Rabbit BQ Reverse Proxy** deployment package. A transparent reverse proxy that sits between your clients (Looker, dbt Cloud, Airflow, etc.) and the BigQuery REST API. It intercepts job submissions (`jobs.insert`, `jobs.query`), calls the Rabbit BQ Job Optimizer to automatically optimize job configuration (e.g. reservation routing), and streams everything else through unchanged with a fail-open design. Includes ready-to-use Terraform for Cloud Run deployment (pulling Rabbit's published container image) and a standalone performance test tool.

- [followrabbit-cli](followrabbit-cli/):
  - Reference for the `followrabbit` CLI — install (brew / npm / curl), authentication, every shipped command and flag, environment variables, exit codes, and troubleshooting. Verified against CLI 0.3.0; the `sql` section describes 0.6.0. Includes the deep-dive on `optimize sq-pricing`, which sets the optimal pricing model (slot reservation or on-demand) on every BigQuery scheduled query in a project using the Rabbit BQ Job Optimizer — the scheduled-query counterpart of the reverse proxy above.

- [vpc-sc-helper](vpc-sc-helper/):
  - A read-only bash helper for customers whose VPC Service Controls perimeters block Rabbit's data loading. Given the violation id(s) from Rabbit's error reports, it finds the denial in your audit logs, names the exact perimeter, and prints the minimal ingress/egress rule plus dry-run-first `gcloud` commands to apply it.

# Quickstart: CLI

The `followrabbit` CLI is what both the plugins and any terminal/CI workflow drive. Zero to first check:

```bash
# 1. Install (Homebrew shown; npm and curl installers in the CLI reference)
brew trust followrabbit-ai/tap        # required on Homebrew 6.x+
brew install followrabbit-ai/tap/followrabbit

# 2. Get an API key at https://subscriptions.agentic.followrabbit.ai, then:
followrabbit auth login --key <YOUR_API_KEY>
# (0.6.0+: if your organisation is set up for Google sign-in with Rabbit,
#  `gcloud auth application-default login` replaces this step. Not for
#  `optimize`, which always needs its own API key)

# 3. Deterministic BigQuery SQL check — no model call, no quota spend (0.2.0+)
# A directory is walked for .sql, .sqlx and .py files and all of them are uploaded; add --no-python to skip the .py files
followrabbit sql models/
```

Full command, flag, environment-variable, and troubleshooting documentation: [followrabbit-cli/README.md](followrabbit-cli/).

# Coding Agent Plugins

This repository includes plugins for **Claude Code**, **Cursor**, and **OpenAI Codex** that bring Rabbit cost optimization directly into your coding agent workflow. The plugins are thin documentation layers — skills teach the AI agent when and how to invoke the `followrabbit` CLI.

## Prerequisites

You'll need the `followrabbit` CLI installed and authenticated locally before invoking the plugin — see the [quickstart](#quickstart-cli) above. The scheduled-query pricing skill uses its own credentials, listed under [Skills](#skills), not the key from the quickstart.

- API keys and pricing: [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai)
- Privacy policy: [followrabbit.ai/en/rabbit-privacy-policy](https://followrabbit.ai/en/rabbit-privacy-policy)
- Terms of service: [followrabbit.ai/en/rabbit-general-terms-and-conditions](https://followrabbit.ai/en/rabbit-general-terms-and-conditions)

The plugin expects the CLI to already be present on PATH — the skill and agent do **not** install software on your behalf. If the CLI is missing, the skill stops and directs you to the install page.

## Installation

All commands below were executed as written against this repository.

**Claude Code:**

```bash
claude plugin marketplace add followrabbit-ai/awesome-rabbit
claude plugin install followrabbit@followrabbit-plugins
```

Or from inside a Claude Code session: `/plugin marketplace add followrabbit-ai/awesome-rabbit`, then `/plugin install followrabbit@followrabbit-plugins`. Refresh updates with `claude plugin marketplace update followrabbit-plugins`.

**Cursor:**

```bash
cursor-agent plugin marketplace add https://github.com/followrabbit-ai/awesome-rabbit
```

Then run `/plugins` inside an interactive `cursor-agent` session to install `followrabbit` from the marketplace. For a local checkout, `cursor-agent --plugin-dir <path-to-clone>` loads the plugin directly.

**OpenAI Codex:**

```bash
codex plugin marketplace add https://github.com/followrabbit-ai/awesome-rabbit
codex plugin add followrabbit@followrabbit
```

Alternatively, inside Codex run `/plugins`, add a new marketplace pointing at this repository, and install `followrabbit` from the directory.

## Skills

- **optimize-bq-compute-pricing-model-scheduled-queries** — Sets the optimal compute pricing model (slot reservation or on-demand) on every BigQuery scheduled query in a GCP project by driving `followrabbit optimize sq-pricing` (CLI 0.3.0+). Always runs `recommend` first, asks before `apply --confirm`, verifies with `status`, and can `revert`. Needs a BQ Job Optimizer API key from [app.followrabbit.ai/api-keys](https://app.followrabbit.ai/api-keys) and Google Application Default Credentials. User-invocable via `/followrabbit:optimize-bq-compute-pricing-model-scheduled-queries`.
- **sql-review** — Deterministic BigQuery SQL best-practice checks via `followrabbit sql` (CLI 0.2.0+; 0.6.0+ for directory runs that include Python DAG files). No LLM and no LLM quota — fast enough to run on every iteration. User-invocable via `/followrabbit:sql-review`.

## Agents

- **scheduled-query-pricing-optimizer** — (Claude Code and Cursor) Activates contextually when you discuss BigQuery scheduled-query pricing, reservation or slot routing, or ask what Rabbit changed. Drives `followrabbit optimize sq-pricing` through the recommend → confirm → apply → verify flow. In Codex, the matching skill provides the same behavior with implicit invocation.

## Data sent to the FollowRabbit API

The plugin skills and agents drive the local `followrabbit` CLI, which talks to `https://api.agentic.followrabbit.ai` (default; overridable with `--api-url`) over HTTPS. Per command:

- `followrabbit context` — local only, no API call.
- `followrabbit status` — sends only your credentials (API key, and the Google ID token described below when present).
- `followrabbit recos list` — sends your git `origin` remote URL (auto-detected) as a `?repo=` query parameter.
- `followrabbit sql` — sends the full contents and the path of every file you name, plus stdin and inline `-q` query text. Pointed at a directory, it walks it and sends every `.sql`, `.sqlx` and `.py` file it finds, so the contents of every Python file under that directory are uploaded unless you pass `--no-python`. The walk skips hidden directories and `node_modules`, `target`, `dbt_packages`, `dbt_modules`, `venv`, `site-packages`, `__pycache__`, `build` and `dist` (a directory you name explicitly is always read); `.gitignore` is not honoured. The server decides which uploaded files hold SQL and reads SQL string literals out of Airflow operator calls in Python files without executing them; files with no SQL it can read come back as skipped. The server keeps per-run counts and rule ids, and a keyed path hash only for keys tied to a customer account — see the [CLI reference](followrabbit-cli/#sql).
- `followrabbit optimize sq-pricing` (`recommend` / `apply`) — sends each BigQuery scheduled query's Data Transfer config in scope (name, display name, schedule, the full SQL and other parameters) plus the project id to the Rabbit BQ Job Optimizer at `https://api.followrabbit.ai/bq-job-optimizer` (overridable with `--optimizer-url`), authenticated with a separate BQ Job Optimizer API key in the `rabbit-api-key` header. Against Google Cloud, with your Application Default Credentials, it lists, reads and (on `--confirm`) patches scheduled queries, and runs one tiny `SELECT 1` probe job per run-as identity and reservation in your project to verify reservation access before writing. `status` and `revert` contact only Google Cloud — see the [CLI reference](followrabbit-cli/#deep-dive-optimize-sq-pricing).

API keys are stored locally under `~/.config/followrabbit/credentials.json` (mode `0600`) and travel only in the `X-Rabbit-Api-Key` request header (never in bodies or URLs). From CLI 0.6.0, when Google Application Default Credentials for a user are present on the machine (`gcloud auth application-default login`), `sql`, `recos list`, `status` and `auth status` also send a Google ID token for that account in the `X-Rabbit-Google-Id-Token` header. It carries your email address and Google Workspace domain so Rabbit can sign you in without an API key; it cannot be used to access Google Cloud, and it is not stored by the CLI. Set `FOLLOWRABBIT_GOOGLE_AUTH=off` to turn this off — see the [CLI reference](followrabbit-cli/#google-sign-in-060). Every request also includes a `User-Agent: followrabbit-cli/<version>` header. The CLI generates no telemetry, analytics, error-reporting, or update-check traffic of its own; server-side, `followrabbit sql` keeps the run record described above.

See [followrabbit.ai/en/rabbit-privacy-policy](https://followrabbit.ai/en/rabbit-privacy-policy) for full details.
