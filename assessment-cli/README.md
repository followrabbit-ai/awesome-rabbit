# rabbit-assessment

A command-line tool that assesses a customer's GCP/BigQuery environment and
quantifies cost-saving opportunities with [Rabbit](https://followrabbit.ai).

It is designed for an operator with **limited visibility** — only project-level
access. Every query is project-scoped, and any project, location, or category
the operator cannot read is **skipped and reported**, never fatal.

## What it collects

For each accessible project, in each requested BigQuery location:

| # | Category | Source |
|---|---|---|
| 2 | Reservations (baseline, idle-slot sharing, autoscale, edition) | `INFORMATION_SCHEMA.RESERVATIONS` |
| 3 | Capacity commitments | `INFORMATION_SCHEMA.CAPACITY_COMMITMENT_CHANGES` |
| 4 | Job pricing-model optimization (on-demand vs. slot) | `INFORMATION_SCHEMA.JOBS_BY_PROJECT` |
| 5 | Storage billing-model optimization (LOGICAL vs. PHYSICAL) | `TABLE_STORAGE` + `SCHEMATA_OPTIONS` |
| 6 | Failed-job cost (capacity-related and general) | `INFORMATION_SCHEMA.JOBS_BY_PROJECT` |
| 7 | Reservation utilization / waste | `JOBS_BY_PROJECT` + `RESERVATION_CHANGES` |

> SKU-level GCP billing (category 1) is intentionally out of scope: actual spend
> is not retrievable via any API without a BigQuery billing export.

## Install

```bash
cd assessment-cli
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
```

## Authenticate

The tool uses Application Default Credentials:

```bash
gcloud auth application-default login
gcloud auth application-default set-quota-project <project-id>
# Needed only for non-USD reports — lets the tool derive the local->USD FX rate:
gcloud services enable cloudbilling.googleapis.com --project=<quota-project>
```

If the Cloud Billing API is disabled, a non-USD run still completes — it just
falls back to a 1:1 USD rate and notes this in the report.

### Required IAM (per assessed project)

- `roles/bigquery.jobUser` — run the queries
- `roles/bigquery.resourceViewer` — see all users' jobs, reservations, commitments
- `roles/bigquery.metadataViewer` — `TABLE_STORAGE`, `SCHEMATA_OPTIONS`
- `roles/browser` (or `resourcemanager.projects.get`) — project enumeration

Missing a role only skips the affected category — the run still completes.

## Usage

```bash
# Single project, last 7 days
rabbit-assess run --scope project:my-project --location US --lookback-days 7

# A folder, two locations, EUR report
rabbit-assess run --scope folder:123456789 \
  --location US --location EU --currency EUR --config pricing.toml

# Render SQL without running anything
rabbit-assess run --scope project:my-project --location US --dry-run

# Regenerate the report from an existing run (no API calls)
rabbit-assess report --run-dir ./rabbit-assessment-output/<run-id>
```

### Key options

| Option | Default | Notes |
|---|---|---|
| `--scope` | required | `org:<id>` \| `folder:<id>` \| `project:<id>` |
| `--location` | required | BigQuery location; repeatable |
| `--lookback-days` | `30` | analysis window |
| `--currency` | `USD` | report's local-currency column; FX is auto-derived |
| `--config` | — | TOML pricing file (negotiated rates) |
| `--categories` | all | restrict to a subset; repeatable |
| `--dry-run` | off | render + print SQL, no queries |

### Pricing config (`pricing.toml`)

```toml
[pricing]
slot_hour_price = 0.04
ondemand_price = 6.25
storage_logical_active_price = 0.02
storage_physical_active_price = 0.04

[pricing.locations.eu]
slot_hour_price = 0.044
```

Precedence: CLI flag > `BQCOST_*` env var > config location override > config
base > built-in BigQuery list price.

## Output

Each run creates `rabbit-assessment-output/<run-id>/`:

```
manifest.json          run parameters, resolved pricing, FX rate, counts
report.md              savings report (coverage, opportunities, detail)
errors.csv             every skipped (project, location, category) with reason
<category>.csv         raw aggregated rows per category
rendered_sql/          the exact SQL that ran, per category
run.log
```

## Currency

Costs are computed in the `--currency` you choose; the report shows every figure
in that currency **and** USD. The local→USD rate is auto-derived at run time from
the Cloud Billing Catalog API by pricing one BigQuery SKU in both currencies. If
the Catalog API is unreachable the report falls back to USD-only.

## Notes & limitations

- `pricing_model_optimization.csv` contains `user_email` (PII).
- Reservation utilization (category 7) counts each project's own jobs only, so a
  reservation serving multiple projects shows more apparent waste than reality.
- List prices are used unless you supply negotiated rates via `--config`.
