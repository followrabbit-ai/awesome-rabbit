---
name: sql-review
description: >
  Run deterministic BigQuery SQL cost checks with `followrabbit sql`.
  Use when the user asks whether a query is expensive, wants SQL checked for
  cost antipatterns before merge, or is editing BigQuery SQL / dbt models and
  mentions cost, scans, partitions, or slots. No LLM involved — fast and does
  not consume LLM quota.
version: 1.3.0
tools: Bash, Read
user-invocable: true
---

# Rabbit SQL Review Skill

## Overview

Thin wrapper around `followrabbit sql`, the on-demand deterministic BigQuery
SQL rule check. The CLI sends the SQL you name to the Rabbit API, which runs
rule checks in memory — no LLM call, no repository scan, no stored SQL. It is
fast and free of LLM quota, so it can run on every iteration.

Requires `followrabbit` CLI **0.2.0 or newer**. If `followrabbit sql --help`
fails with an unknown-command error, tell the user to upgrade
(`brew upgrade followrabbit-ai/tap/followrabbit`) and stop.
The CLI must be authenticated (`followrabbit auth status`); any valid API key
works. Do not install software on the user's behalf.

## When to Use

- "Is this query expensive?" / "check this SQL for cost issues"
- Before merging changes to `.sql` files or compiled dbt models
- The user mentions BigQuery scan cost, partitions, clustering, or slots
  while editing SQL

## Data sent to the Rabbit API

`followrabbit sql` sends the contents of the files you name to the Rabbit API.
They are analysed in memory and the SQL text is not retained. Finding metadata
and a hashed form of the file path are kept to measure which recommendations
are useful. No credentials, git history, or telemetry beyond that is sent.

## Running checks

```bash
followrabbit sql query.sql                 # one file
followrabbit sql models/ transforms/       # directories (walked for *.sql, *.sqlx)
cat q.sql | followrabbit sql               # stdin
followrabbit sql -q "SELECT * FROM \`p.d.t\`"   # inline SQL
```

Use `--json` when capturing output for parsing (auto-enabled when piped).
`--all` prints every finding when the default listing is capped.

Notes that prevent wrong conclusions:

- **Directory walks apply a BigQuery dialect gate**: files not recognised as
  BigQuery are reported as skipped (`not_bigquery`), not analysed. Inline
  `-q` and stdin input is always treated as BigQuery.
- **Raw dbt / Jinja models are skipped** (`unresolved_templating`). Run
  `dbt compile` and point the skill at `target/compiled/` instead.

## Presenting results

- Group findings by file. For each: severity level (high / medium / low), the
  message, and the suggested fix when present.
- A finding marked `measure_first` should be presented as "measure before
  applying" — do not auto-apply it.
- **Always report the checked and skipped counts and the skip reasons.** Zero
  findings with skipped files is not a clean bill of health — say what was
  skipped and why (most often templating; suggest the dbt compile path).
- Offer to apply straightforward fixes to the SQL; let the user decide.

## CI usage

`--fail-on high|medium|low` makes the command exit 7 when a finding at or
above that level exists. Exit 0 means the check ran, findings included.

| Exit | Meaning |
|---|---|
| `0` | Ran successfully (findings may exist) |
| `2` | Auth |
| `3` | Rate limited |
| `4` | Input error |
| `5` | API error |
| `6` | Network |
| `7` | Findings at or above `--fail-on` |
