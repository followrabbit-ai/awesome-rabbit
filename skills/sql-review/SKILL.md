---
name: sql-review
description: >
  Run deterministic BigQuery SQL best-practice checks with `followrabbit sql`.
  Use when the user wants BigQuery SQL checked for cost antipatterns before
  commit, or is editing BigQuery SQL / dbt models and mentions cost, scans,
  partitions, or slots. No LLM involved — fast and does not consume LLM quota.
version: 1.1.0
tools: Bash, Read
user-invocable: true
---

# Rabbit SQL Review Skill

## Overview

Thin wrapper around `followrabbit sql`, the on-demand deterministic BigQuery
SQL rule check. The CLI sends the files, directories, stdin or inline query you
give it to the Rabbit API, which runs rule checks in memory — no LLM call, no
stored SQL. A directory is walked for `.sql`, `.sqlx` and `.py` files and all of
them are uploaded (see Data sent below). It is fast and free of LLM quota, so it
can run on every iteration.

Requires `followrabbit` CLI **0.2.0 or newer**; **0.5.1 or newer** for directory
runs that include Python files (0.5.0 caps a run at 500 files and about 5 MB).
If `followrabbit sql --help`
fails with an unknown-command error, tell the user to upgrade
(`brew upgrade followrabbit-ai/tap/followrabbit`) and stop.
The CLI must be authenticated (`followrabbit auth status`); any valid API key
works. Do not install software on the user's behalf.

## When to Use

- "Check this SQL for cost antipatterns" / "does this query follow best practices?"
- Before committing changes to BigQuery `.sql` files or compiled dbt models
- The user mentions BigQuery scan cost, partitions, clustering, or slots
  while editing SQL

## Data sent to the Rabbit API

`followrabbit sql` sends the full contents and the path of every file you name,
plus stdin and inline `-q` text, to the Rabbit API. Given a directory, it also
sends every `.sql`, `.sqlx` and `.py` file the walk finds, so the contents of
every Python file under that directory are uploaded unless `--no-python` is
passed. The walk skips hidden directories and `node_modules`, `target`,
`dbt_packages`, `dbt_modules`, `venv`, `site-packages`, `__pycache__`, `build`
and `dist` (a directory named explicitly is always read); `.gitignore` is not
honoured. The server decides which files hold SQL and parses Python files
(without executing them) to read SQL out of Airflow operator calls; files with
no SQL come back skipped. Tell the user this before running on a directory with
Python files they may not want uploaded.

The SQL is analysed in memory and the SQL text is not retained. Finding
metadata and a hashed form of the file path are kept to measure which
recommendations are useful. No credentials, git history, or telemetry beyond
that is sent.

## Running checks

```bash
followrabbit sql query.sql                 # one file
followrabbit sql models/ transforms/       # directories (walked for *.sql, *.sqlx, *.py)
followrabbit sql dags/ --no-python         # directory, without uploading Python files
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
- **Skip reasons**: `no_sql` (no SQL the server can read, which is what an
  ordinary Python module gets; walked `.sqlx` files also currently come back
  this way), `not_bigquery`, `unresolved_templating`, `parse_error`,
  `too_large` (over 128 KB), `empty`.
- **Size limit**: up to 5000 files per run (0.5.1 sends large runs in several
  requests). Over that, nothing is sent and the error `TOO_MANY_FILES` says to
  run per subfolder or pass `--no-python`.

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
