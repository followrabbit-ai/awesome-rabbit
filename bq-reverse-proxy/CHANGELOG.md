# Changelog

Release notes for the BQ Reverse Proxy image. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/). Each version is an image tag (`v<version>`) in
the three regional mirrors:

- `europe-docker.pkg.dev/followrabbit-ai-public/images/bq-reverse-proxy`
- `us-docker.pkg.dev/followrabbit-ai-public/images/bq-reverse-proxy`
- `asia-docker.pkg.dev/followrabbit-ai-public/images/bq-reverse-proxy`

The registry is public: listing tags and pulling need no Google credentials.
The digest under each version is the same on all three mirrors. Pin it
(`...bq-reverse-proxy@sha256:...`) if you want an immutable reference.

## [0.4.0] - RELEASE_DATE

Image digest: `sha256:IMAGE_DIGEST`

### Changed

- **`/metrics` is no longer served on the proxy URL by default.** On a service
  that allows unauthenticated calls, anyone who knew the URL could read the
  Prometheus counters, which carry project IDs and job counts per project. The
  endpoint is now served only when `METRICS_PORT` is set: a port of its own
  serves it there only (not reachable from outside a Cloud Run instance; use it
  on Kubernetes or with a collector sidecar), and the same value as `PORT`
  keeps the old behaviour. With `METRICS_PORT` unset, `/metrics` on the proxy
  URL answers 404. **If you scrape `/metrics` today, set `METRICS_PORT` when
  you upgrade** (Terraform module: `extra_env = { METRICS_PORT = "..." }`).

### Added

- **Log events for every counter**, so the proxy can be monitored on Cloud Run
  without scraping it. Each increment of `bq_proxy_optimize_total`,
  `bq_proxy_fail_open_total` and `bq_proxy_reroute_total` is also written as
  one `INFO` JSON log line with an `event` field (`optimize`, `fail_open`,
  `reroute`) and the counter's labels as fields (`project`, `outcome`,
  `reason`). Cloud Logging log-based metrics built on these lines give the
  same numbers across all instances; the Terraform module creates them with
  `create_log_metrics = true`. Needs `LOG_LEVEL` `info` (the default) or
  `debug`.

## [0.3.1] - 2026-11-18

Image digest: `sha256:565bd6d803628a15c3e2512b2f4239825a29d8af17621d10521b537f7a3c4d1e`

### Fixed

- **An optimizer 401/403 no longer blocks the BigQuery job.** The proxy used
  to return the optimizer's 401/403 to the BigQuery client, so a Rabbit-side
  auth outage stopped customer jobs. It now fails open exactly as on any other
  optimizer error: the original request goes to BigQuery unchanged and the job
  runs unoptimized. A rejected key stays visible: it is logged at ERROR with
  the status and counted under `bq_proxy_fail_open_total{reason="optimizer_auth"}`
  (as well as `bq_proxy_optimize_total{outcome="auth_error"}`). The
  `X-Rabbit-Proxy-Error: optimizer-auth` response header is gone with it.

## [0.3.0] - 2026-09-18

Image digest: `sha256:6186e83b1c98e41a1cd1f001e1e065bd98076051992998ead91a2eb23bab581d`

### Added

- **On-demand pool rerouting** (`ENABLE_POOL_REROUTE`): when the optimizer
  places a job in a dedicated on-demand pool project, the proxy moves it there
  — rewriting the request path and, for `jobs.insert`,
  `jobReference.projectId`. Off by default; enabling it requires
  `BQ_JOB_OPTIMIZER_URL` and an API key. The pool projects are read from the
  optimizer (`GET /v1/pool-projects`, refreshed every five minutes), so there
  is no pool configuration on the proxy to keep in step.

  Two prerequisites decide whether this can work at all in a given topology,
  and both are properties of the deployment rather than of the proxy:

  1. **Identity.** The job is submitted with the CALLER's credentials, not
     Rabbit's. Every routed user or service account needs
     `bigquery.jobs.create` on each pool project — and, since a job-scoped call
     is resolved against the project that actually ran the job, whatever that
     call requires there too (`bigquery.jobs.delete` for `jobs.delete`, for
     instance). Missing one surfaces as the pool project's own 403, not as a
     routing failure.
  2. **Perimeter.** A routed job is billed to the pool project but still reads
     the original data. If VPC Service Controls permit the source project but
     not the pool projects, the job is refused no matter how the IAM is set —
     granting the roles above converts a 403 into a VPC-SC denial rather than
     fixing it. Put the pool projects inside the same perimeter as the data
     they will read.

  Both are worth confirming before enabling the feature: neither is detectable
  from the proxy's configuration, and both surface only once real jobs are
  being placed.
- **Client-agnostic job lookup** for `jobs.get`, `jobs.getQueryResults`,
  `jobs.cancel` and `jobs.delete`. A client that adopts the `jobReference`
  BigQuery returns already addresses the pool project and passes straight
  through. One that re-addresses jobs by bare id against its own project —
  Airflow's `BigQueryInsertJobOperator`, dbt's `cancel_open` — is resolved
  transparently: from an in-process cache when known, otherwise by probing the
  allowlisted pool projects concurrently once BigQuery reports the job is not
  where the client asked. The job id is taken from BigQuery's response rather
  than the request, so clients that leave `jobReference` off a `jobs.insert`
  (it is optional, and `jobs.query` has none) are remembered too. `jobs.list`
  is not covered — a listing against the source project will not show rerouted
  jobs.
- Metrics `bq_proxy_reroute_total{outcome}` (`routed` and the reasons a
  placement was declined) and `bq_proxy_job_lookup_total{result}`
  (`cache_hit` / `fanout_hit` / `fanout_miss` / `fanout_suppressed`).
- A job id found in no pool project is remembered for a few seconds, so a
  client retrying against a missing id is searched for once rather than on
  every attempt, and concurrent searches are bounded. Without this a retry loop
  repeats the whole search on every attempt, multiplying the calls made on the
  caller's credentials by the number of pool projects.

### Changed

- `bq_proxy_requests_total` now carries the request's real HTTP method. It was
  hardcoded to `POST`, which mislabelled every pass-through GET and DELETE —
  including the job-scoped routes this release adds.
- The proxy now reads `context.targetProjectId` from the optimizer's
  `/v1/jobs.insert` and `/v1/jobs.query` responses, and falls back to
  `context.optimizationResults` when the audit trail is not at the top level.
  With an optimizer that does not send a placement the proxy is unchanged:
  no rerouting, no lookups, no probes.

### Fixed

- On-demand pool rerouting no longer fails open against the optimizer-response
  validation added in this release. A pool placement legitimately moves
  `jobReference.projectId` to the pool project, which the validator refused —
  so with both features on, every routed job fell back to the client's original
  request: no pooling, and no pricing decision either. The validator now accepts
  that one field, and only when it names the exact project this request is being
  rerouted to.
- The pool-projects refresh no longer inherits `BQ_JOB_OPTIMIZER_TIMEOUT`. That
  timeout is deliberately tiny because the per-job call blocks a BigQuery
  request; applying it to a five-minutely background refresh meant an optimizer
  cold start or rollout left the proxy with no pool list — declining every
  placement and unable to resolve job-scoped calls for jobs already running in a
  pool. Background calls now get their own 30s budget on a shared transport.
- The start-up pool load is retried with capped exponential backoff instead of
  waiting a full refresh interval. Before the first success there is no
  last-good list to fall back on, so a single unlucky moment disabled rerouting
  for five minutes.

### Security

- **The optimizer's response is now validated before it is forwarded.** The
  proxy replaces the client's request body with the optimizer's
  `optimizedRequest`, which BigQuery then executes under the *caller's*
  credentials — so a compromised or buggy optimizer could otherwise run
  different SQL or write to a different table within permissions the caller
  already holds. Only the pricing surface may change: `configuration.reservation`,
  `rabbit-`-prefixed labels, and the query text *solely* by inserted
  `SET @@reservation` statements. Destination table, write/create disposition,
  default dataset, `jobReference`, dry-run and the load/copy/extract
  configurations are protected by omission. A violation is treated like any
  other optimizer failure: the client's original request is forwarded unchanged
  and `bq_proxy_fail_open_total{reason="unexpected_body_change"}` increments.
  The statement-level check is an exact inverse of the rewriter (which only ever
  inserts), so it needs no knowledge of whether statement-level is enabled: with
  it off, nothing is injected and the rule reduces to "the SQL must be
  identical".
- **Redirects are no longer followed** on any outbound client — optimizer calls,
  the background pool refresh, and job-scoped probes. Go strips only
  `Authorization`/`Cookie` across a cross-host redirect, so `rabbit-api-key`
  would have travelled to the redirect target, and a 307/308 preserves the
  request body (the caller's SQL) with it. A 3xx now surfaces to our own code,
  which fails open.

## [0.2.1] - 2026-08-01

Image digest: `sha256:cf4e496b79497959773dafda8b1206054564faab3a338756bb3dcea9de13ee2d`

### Changed

- Dependencies: `github.com/prometheus/client_golang` 1.23.2 → 1.24.0 in the
  proxy image.

## [0.2.0] - 2026-08-01

Image digest: `sha256:bd74298695ae2db978efb4f0957ca13a4b80b282c261320da856d3fc476c3cc0`

### Added

- **Multiple API keys via path-alias routing** (`API_KEY_ROUTES`):
  route each workload to its own Rabbit API key by pointing its BigQuery
  endpoint at `https://<proxy>/<alias>`. The alias segment is stripped
  before forwarding; keys never appear in URLs or logs.
- **Reserved `default` alias in `API_KEY_ROUTES`**: sets the fallback
  (root) key, equivalent to `DEFAULT_API_KEY` — one env var, and therefore
  one Secret Manager secret, can carry every key. Setting both is a startup
  config error; `/default/...` never routes.
- **Per-workload optimizer config** (`OPTIMIZER_CONFIGS`): map a route
  alias — or `default` for root traffic — to a JSON optimizer config
  (`reservationIds`, `statementLevelOverride`). Forwarded verbatim to the
  optimizer via the `x-rabbit-optimizer-config` header, where it takes
  precedence over the API key's server-side configuration. Self-service
  per-deployment optimizer control; the pricing mode stays derived per job
  project and is not settable from this path. Configs are logged verbatim
  at startup and attributed per request on the optimizer side
  (`configSource: header`).

## [0.1.1] - 2026-07-07

Image digest: `sha256:076bc84b537ada2559eee0be72b6f41e22b23c76702cd4b85d66da531b913752`

### Fixed

- Stamp `VERSION`/`COMMIT` build args into published images.

### Changed

- The single canonical Terraform module now lives in this repository, in
  [`terraform/`](terraform/).

## [0.1.0] - 2026-07-06

Image digest: `sha256:9247b3fe09fe71f30d001d4a4f1089d70a831dbc332bcce4e4dc3fec0f8a0448`

Initial public release: transparent BigQuery reverse proxy for Cloud Run —
fail-open optimizer interception of `jobs.insert`/`jobs.query`, OAuth
pass-through, streaming responses, Prometheus metrics, signed images with
SBOM.
