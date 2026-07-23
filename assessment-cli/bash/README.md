# rabbit-assess (Bash port)

A dependency-light Bash port of the Python [`rabbit-assess`](../README.md) tool,
for hosts that **cannot run Python 3** (e.g. a locked-down box that only has
Python 2).

It produces the same assessment — projects under a scope, 6 cost categories,
per-category CSVs, and a Markdown report — by orchestrating tools a GCP operator
already has, instead of Python libraries.

## Why this exists

The Python tool needs Python ≥ 3.11 and modern GCP client libraries. Where that
isn't possible, this port leans entirely on the **Google Cloud SDK**, which the
operator already uses for GCP work.

## Requirements

| Need | Notes |
|---|---|
| `bash` ≥ 4.2 | CentOS 7 ships exactly 4.2; the script enforces this |
| `gcloud` | project enumeration |
| `bq` | runs the BigQuery queries (Cloud SDK; bundles its own Python) |
| coreutils | `awk`, `sed`, `sort`, `date` … — standard on any Linux |

**No `jq`, no Python, no `pip`, nothing to install.** Authentication is whatever
`gcloud`/`bq` already use (`gcloud auth login` / a service account).

## Usage

```bash
./rabbit-assess.sh --scope folder:123456789 --location US --location EU

# single project, 7-day window
./rabbit-assess.sh --scope project:my-project --location US --lookback-days 7

# non-USD report (FX rate is supplied, not auto-derived)
./rabbit-assess.sh --scope org:123 --location EU --currency EUR --exchange-rate 1.08

# render the SQL without running anything
./rabbit-assess.sh --scope project:my-project --location US --dry-run
```

Run `./rabbit-assess.sh --help` for the full option list. Options mirror the
Python tool, with one difference: the local→USD rate is **`--exchange-rate`**
(supplied manually; the Bash port does not auto-derive it).

## Shipping to an offline / locked-down host

`bundle.sh` packs the script and the SQL templates into one tarball:

```bash
./bundle.sh                       # creates dist/rabbit-assess-bash.tar.gz
```

Copy that tarball to the target host, then:

```bash
tar -xzf rabbit-assess-bash.tar.gz
cd rabbit-assess-bash
./rabbit-assess.sh --scope folder:<id> --location US
```

The script auto-detects the bundled `sql_templates/` directory beside it.

## Output

Each run writes `rabbit-assessment-output/<run-id>/`:

```
report.md            savings report (coverage, opportunities, samples)
manifest.txt         run parameters and counts (key=value)
errors.csv           every skipped (project, location, category) — short index
query-errors.log     full error text + the failing SQL for each skip
run.log              full run log
<category>.csv        raw aggregated rows per category
```

Any project, location, or category the operator cannot read is **skipped and
recorded** — the run always completes. `errors.csv` is the short index;
`query-errors.log` has the full `bq` error and the exact SQL that failed, for
investigation.

## Differences vs. the Python tool

- **FX rate is manual** (`--exchange-rate`) — no Cloud Billing Catalog API call.
- **Serial execution** — one query at a time (the Python tool is concurrent).
- **No unit tests / type checking** — it is a thin orchestration script.

The SQL templates are shared with the Python tool (`../src/rabbit_assessment/sql_templates/`)
— a single source of truth. Both tools run byte-for-byte the same queries.
