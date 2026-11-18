---
name: sql-review
description: >
  Check BigQuery SQL and dbt models for cost best practices with
  `followrabbit sql`, judge each finding against the actual query, and report
  only what matters. Use when the user wants BigQuery SQL or dbt models checked
  for cost antipatterns before commit, or is editing BigQuery SQL or dbt models
  and mentions cost, scans, partitions, or slots. The checks are deterministic:
  no LLM call on the Rabbit side and no LLM quota used.
version: 1.2.0
tools: Bash, Read
user-invocable: true
---

# Rabbit SQL Review Skill

## Overview

`followrabbit sql` sends SQL to the Rabbit API, which runs deterministic
BigQuery best-practice checks in memory and returns findings. Your job: give it
the right input, judge each finding against the query it flags, present what
matters, and send a verdict back for each finding you decided.

Requires CLI **0.2.0+**; **0.6.0+** for directory runs that include Python
files; **0.7.0+** for finding ids and `sql feedback`. If
`followrabbit sql --help` fails with an unknown-command error, tell the user to
upgrade (`brew upgrade followrabbit-ai/tap/followrabbit`) and stop. The CLI must
be authenticated (`followrabbit auth status`): an API key, or from 0.6.0 Google
sign-in via `gcloud auth application-default login` where the organisation is
set up for it. Do not install software or run a login on the user's behalf.

## Data sent to the Rabbit API

`followrabbit sql` sends the full contents and the path of every file you name,
plus stdin and inline `-q` text. Given a directory, it also sends every `.sql`,
`.sqlx` and `.py` file the walk finds, so every Python file under that directory
is uploaded unless `--no-python` is passed. The walk skips hidden directories and
`node_modules`, `target`, `dbt_packages`, `dbt_modules`, `venv`,
`site-packages`, `__pycache__`, `build` and `dist` (a directory named explicitly
is always read); `.gitignore` is not honoured. Python files are parsed, not
executed, to read SQL out of Airflow operator calls. Tell the user this before
running on a directory with Python files they may not want uploaded.

The SQL text is analysed in memory and not kept. Rabbit keeps finding metadata,
a hashed file path, and the verdicts sent with `sql feedback`, to measure which
recommendations are useful. For each request it also records the signed-in
email (or the API key owner's email), the key id, the CLI version, the command
and its outcome; the email is kept for up to 13 months. Nothing else from the
repository is sent.

## 1. Choose the input

**dbt models.** This flow is written for dbt Core. It applies when a
`dbt_project.yml` sits at or above the SQL in scope. The project name is its
`name:` value; compiled SQL is under `target/compiled/<name>/` with the same
relative path as the model (`models/marts/orders.sql` becomes
`target/compiled/<name>/models/marts/orders.sql`). `target` is the default:
`--target-path`, the `DBT_TARGET_PATH` environment variable, or the
deprecated `target-path:` key in `dbt_project.yml` put it elsewhere.

1. If the compiled files for the models in scope exist and are newer than those
   model files (compare with `ls -l`), check the compiled files. Name them or
   their directory explicitly: a walk from the project root skips `target/`.
2. If they are missing or older, offer to run `dbt compile` with a selection
   limited to the models in scope (`dbt compile --select orders customers`, run
   from the directory holding `dbt_project.yml`). Say in one line that a
   compile uses their own dbt profile and warehouse credentials and may run
   small lookup queries. Wait for a yes. Never compile unasked. Never install
   dbt or run a login.
3. If the user declines, `dbt --version` fails, or the compile fails, say which
   models were not checked. (Raw models can still be passed: Jinja that is only
   `ref()` / `source()` is checked with less information, a Jinja block standing
   for a whole clause is skipped.) Describe the CI path: a step after the
   pipeline's own `dbt compile` running
   `followrabbit sql target/compiled/<name>/ --fail-on high`, authenticated
   with an API key (for CI access write to support@followrabbit.ai).
4. Report each finding against the model source file, not the compiled path.
   Compiled line numbers differ: read the model and give the line of the flagged
   statement there.

**Other templated SQL.** `${...}` or `{{ ... }}` placeholders that stand for a
name or a value are checked as written. Ones that stand for a whole clause make
the file skip as `unresolved_templating`. The remedy is to check the rendered
SQL, what the pipeline actually submits (pipe it in on stdin with
`--stdin-filename <original path>`), not `dbt compile`. If the rendered SQL is
not available, report the file as not checked.

## 2. Run the check

```bash
followrabbit sql query.sql                 # one file
followrabbit sql models/ transforms/       # directories (walked for *.sql, *.sqlx, *.py)
followrabbit sql dags/ --no-python         # directory, without uploading Python files
cat q.sql | followrabbit sql --stdin-filename q.sql   # stdin
followrabbit sql -q "SELECT * FROM \`p.d.t\`"   # inline SQL
```

Use `--json` (automatic when output is piped). Under `data`, `findings` holds
each finding (`id`, `file`, `start_line`, `end_line`, `level` high / medium /
low, `message`, optional `fix`, `measure_first`) and `summary` holds `findings`,
`checked`, `skipped` and `skipped_by_reason`. Add `--files` for the per-file
list, for example to name the skipped files, and `--all` when the listing says
it is capped. Older CLIs always include the per-file list (`files`, each with a
`status` and a skip `reason`), have no `skipped_by_reason`, and their findings
carry no `id`: count the skip reasons from `files`; everything below works
except feedback.

Walked files pass a BigQuery dialect gate; named files, `-q` and stdin do not.
Skip reasons: `no_sql` (ordinary Python modules, and walked `.sqlx` files),
`not_bigquery`, `unresolved_templating`, `parse_error`, `too_large` (over
128 KB), `empty`. Over 5000 files nothing is sent (`TOO_MANY_FILES`): run per
subfolder or pass `--no-python`.

## 3. Judge each finding

Read each flagged statement in full before deciding. Keep a finding only when
it matters for this query; the pattern being present is not enough. Typical
reasons to set one aside: the full scan is the purpose (a history backfill, a
reconciliation, a min or max over all time); the table is known to be small;
exact results are required where an approximation was suggested; the ordering
is the purpose of the query.

Do not invent facts about table sizes. When you cannot tell, keep the finding,
mark it undecided, and say what would settle it (for example the table's
size).

## 4. Present

- Kept findings grouped by file. For each: level, what it costs in this query,
  and the concrete change. A finding with `measure_first` is presented as
  "measure before applying"; never apply it without that step.
- One line for what you set aside, with the count and the reasons, so the user
  can ask to see them.
- Always the checked and skipped counts, with the skip reasons. Zero findings
  with skipped files is not a clean bill of health.
- When nothing relevant remains, say so plainly in one or two sentences, with
  what was checked and what was skipped.
- Offer to apply straightforward fixes; let the user decide.
- If step 5 will send feedback and you have not said so yet in this session,
  end with one line: a verdict per finding is sent to Rabbit, and
  `FOLLOWRABBIT_NO_FEEDBACK=1` turns this off. This comes before the first
  send.

## 5. Send feedback

After presenting, send one verdict for each finding you decided, all in one
call. Do not ask the user each time. Verdicts: `useful` for a finding kept
because it matters here, `wrong` for one set aside because it does not hold
here, `intentional` for one set aside because the pattern is deliberate. A
finding kept only because you could not tell gets no verdict. Each verdict
gets a one-line reason (at most 300 characters)
about why the finding did or did not apply. No SQL text, no names of people, no
secrets.

```bash
followrabbit sql feedback <<'EOF'
[{"id": "<id>", "verdict": "intentional", "reason": "full scan is the point: reconciliation over all history"}]
EOF
```

Skip this step when `FOLLOWRABBIT_NO_FEEDBACK=1` is set, when findings carry
no `id`, or when `followrabbit sql feedback --help` fails or shows only the
general `sql` help; the notice in step 4 is then left out too. If the send
fails, say so in one line; the review still stands.

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
