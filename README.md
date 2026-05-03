# awesome-rabbit

This repository aims to provide tools, scripts, and code snippets for current and potential Rabbit users. Whether you're just getting started or looking to enhance your experience, you'll find helpful resources here to support your journey with Rabbit.

# Content

- [assessment/bigquery-reservation-waste](assessment/bigquery-reservation-waste/):
  - SQL scripts for analyzing BigQuery reservation slot waste, helping you identify underutilized reservations and optimize costs.

- [assessment/bq-pricing-model-optimization](assessment/bq-pricing-model-optimization/):
  - SQL scripts for analyzing and optimizing BigQuery pricing models at both the project and organization level.

- [gcs-insights-and-usage-logs](gcs-insights-and-usage-logs/):
  - Rabbit is capable of providing deep folder or object level insights and storage class recommendations with automated class management based on the access patterns. In order to do this, we need to enable Storage Insights and Usage Logs on the target buckets. This Terraform module is designed to configure Google Cloud Storage Insights and Usage Logs for specified target buckets. It automates the setup of necessary resources, including report buckets, IAM roles, and report configurations.

- [bq-backup-and-restore](bq-backup-and-restore/):
  - A command-line tool for creating and restoring backups of BigQuery datasets. Supports backing up all datasets in a project or specific datasets, with options for current state or point-in-time backups (last 7 days). Only backs up tables, excluding views, models, and other non-table objects.

- [bq-proxy](bq-proxy/):
  - A BigQuery dynamic pricing proxy that sits between your clients (Looker, dbt Cloud, Airflow, etc.) and the BigQuery REST API. It intercepts query and job requests, calls the Rabbit BQ Job Optimizer to automatically optimize job configuration (e.g. reservation routing), and streams responses transparently. Includes Terraform for Cloud Run deployment and a standalone performance test tool.

- [bq-scheduled-query-pricing-optimizer](bq-scheduled-query-pricing-optimizer/):
  - Set the optimal pricing model — slot-reservation or on-demand — on every BigQuery scheduled query in a project or GCP folder, in one command. Driven by the `followrabbit` CLI; rewrites each managed scheduled query with a fenced `SET @@reservation` statement and a tracking label. Idempotent re-runs, dry-run by default, full revert support.

# Coding Agent Plugins

This repository includes plugins for **Claude Code**, **Cursor**, and **OpenAI Codex** that bring FollowRabbit cost optimization directly into your coding agent workflow. The plugins are thin documentation layers — skills teach the AI agent when and how to invoke the `followrabbit` CLI.

## Prerequisites

Install and authenticate the [followrabbit CLI](https://followrabbit.ai):

```bash
brew install followrabbit-ai/tap/followrabbit
followrabbit auth login --key <YOUR_API_KEY>
```

Get your API key at [subscriptions.agentic.followrabbit.ai](https://subscriptions.agentic.followrabbit.ai). The skill will auto-install the CLI if it's missing.

## Installation

**Claude Code:**

```bash
claude plugin install followrabbit
```

**Cursor:**

Install via Cursor Settings > Plugins > search "followrabbit", or point Cursor to this repository locally.

**OpenAI Codex:**

Add this repository as a Codex plugin marketplace, then install the plugin:

```bash
codex plugin marketplace add https://github.com/followrabbit-ai/awesome-rabbit
codex plugin install followrabbit
```

Alternatively, inside Codex run `/plugins`, add a new marketplace pointing at this repository, and install `followrabbit` from the directory.

## Skills

- **cost-review** — Scans local Terraform and SQL files, runs AI-powered cost analysis via the FollowRabbit API, presents optimization instructions, and offers to apply suggestions directly to code. User-invocable via `/followrabbit:cost-review`.

## Agent

- **cost-optimizer** — (Claude Code only) Activates contextually when you discuss Terraform costs, pricing, savings, or resource sizing. Runs `followrabbit costreview` and can list recommendations with `followrabbit recos list`. In Codex, the same proactive behavior is provided by the `cost-review` skill with implicit invocation enabled.
