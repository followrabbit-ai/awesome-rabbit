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
  - Reference for the `followrabbit` CLI — install (brew / npm / curl), authentication, every shipped command and flag, environment variables, exit codes, and troubleshooting. Verified against the shipped binary. Includes the deep-dive on `optimize sq-pricing`, which sets the optimal pricing model (slot reservation or on-demand) on every BigQuery scheduled query in a project using the Rabbit BQ Job Optimizer — the scheduled-query counterpart of the reverse proxy above.

- [vpc-sc-helper](vpc-sc-helper/):
  - A read-only bash helper for customers whose VPC Service Controls perimeters block Rabbit's data loading. Given the violation id(s) from Rabbit's error reports, it finds the denial in your audit logs, names the exact perimeter, and prints the minimal ingress/egress rule plus dry-run-first `gcloud` commands to apply it.

# Quickstart: CLI

The `followrabbit` CLI is what both the plugins and any terminal/CI workflow drive. Zero to first review:

```bash
# 1. Install (Homebrew shown; npm and curl installers in the CLI reference)
brew trust followrabbit-ai/tap        # required on Homebrew 6.x+
brew install followrabbit-ai/tap/followrabbit

# 2. Get an API key at https://subscriptions.agentic.followrabbit.ai, then:
followrabbit auth login --key <YOUR_API_KEY>

# 3. First cost review of your Terraform / SQL
followrabbit costreview --dir ./infra --types tf,sql

# 4. Deterministic BigQuery SQL check — no model call, no quota spend (0.2.0+)
followrabbit sql models/
```

Full command, flag, environment-variable, and troubleshooting documentation: [followrabbit-cli/README.md](followrabbit-cli/).

# Coding Agent Plugins

This repository includes plugins for **Claude Code**, **Cursor**, and **OpenAI Codex** that bring Rabbit cost optimization directly into your coding agent workflow. The plugins are thin documentation layers — skills teach the AI agent when and how to invoke the `followrabbit` CLI.

## Prerequisites

You'll need the `followrabbit` CLI installed and authenticated locally before invoking the plugin — see the [quickstart](#quickstart-cli) above.

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

- **cost-review** — Scans local Terraform and SQL files, runs AI-powered cost analysis via the FollowRabbit API, presents optimization instructions, and offers to apply suggestions directly to code. User-invocable via `/followrabbit:cost-review`.

## Agent

- **cost-optimizer** — (Claude Code and Cursor) Activates contextually when you discuss Terraform costs, pricing, savings, or resource sizing. Runs `followrabbit costreview` and can list recommendations with `followrabbit recos list`. In Codex, the same proactive behavior is provided by the `cost-review` skill with implicit invocation enabled.

## Data sent to the FollowRabbit API

When the `cost-review` skill or `cost-optimizer` agent runs, the local `followrabbit` CLI's `costreview` command sends data to `https://api.agentic.followrabbit.ai` (default; overridable with `--api-url`) over HTTPS:

- **Full file contents of every `*.tf`, `*.tfvars`, and `*.tfvars.json` file** under the working directory, up to a combined 512 KiB budget. For files over the budget, the raw content is omitted, but their extracted resource blocks — including every quoted attribute value — are still transmitted in the resource index described below.
- **Full file contents of every `*.sql` file** under the working directory, with each file capped at 100 KiB. There is no aggregate SQL budget on the client; the server caps the total uploaded context at 500,000 characters and rejects anything larger with `400 INVALID_REQUEST` — see [troubleshooting](followrabbit-cli/#troubleshooting).
- **Relative paths** (from the scan root) of every file listed above.
- A summarized index of Terraform resources, modules, and `.tfvars` environment files extracted from those files (alongside, not instead of, the raw content).
- The skill IDs requested and, optionally, a model override.

It does **not** send file contents outside `*.tf` / `*.tfvars` / `*.tfvars.json` / `*.sql`, the absolute working-directory path, your hostname, username, OS, environment variables, `.git/` history, or branch state. Directories whose name starts with `.` (e.g. `.git`, `.terraform`) and `node_modules` are skipped during the scan.

The CLI does **not** read or honor `.gitignore` — any non-hidden directory listed in `.gitignore` will still be scanned.

Other commands:

- `followrabbit context` — local only, no API call.
- `followrabbit status` — sends only your API key.
- `followrabbit recos list` — sends your git `origin` remote URL (auto-detected) as a `?repo=` query parameter.
- `followrabbit sql` — sends only the SQL files you name (contents and relative paths); no repository scan. The server keeps per-run counts and rule ids, and a keyed path hash only for keys tied to a customer account — see the [CLI reference](followrabbit-cli/#sql).

API keys are stored locally under `~/.config/followrabbit/credentials.json` (mode `0600`) and travel only in the `X-Rabbit-Api-Key` request header (never in bodies or URLs). Every request also includes a `User-Agent: followrabbit-cli/<version>` header. The CLI generates no telemetry, analytics, error-reporting, or update-check traffic of its own; server-side, `followrabbit sql` keeps the run record described above.

See [followrabbit.ai/en/rabbit-privacy-policy](https://followrabbit.ai/en/rabbit-privacy-policy) for full details.
