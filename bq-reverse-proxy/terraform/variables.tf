# -----------------------------------------------------------------------
# Required
# -----------------------------------------------------------------------

variable "project_id" {
  type        = string
  description = "GCP project where the proxy Cloud Run service will live."
}

variable "region" {
  type        = string
  description = "Region for the Cloud Run service (e.g. europe-west3)."
}

variable "bq_job_optimizer_url" {
  type        = string
  description = <<EOT
HTTPS base URL of the Rabbit BQ Job Optimizer service. The default is the
global public endpoint — correct for all deployments. Set to empty string
("") for pure pass-through mode (no optimizer calls). If you override,
verify the URL actually serves — the proxy fails open, so an unreachable
optimizer silently disables optimization.
EOT
  default     = "https://api.followrabbit.ai/bq-job-optimizer"
}

# -----------------------------------------------------------------------
# Image selection
# -----------------------------------------------------------------------

variable "image_registry" {
  type        = string
  description = <<EOT
Artifact Registry path up to but not including the :tag. Defaults to the
central Rabbit-hosted registry. allAuthenticatedUsers has reader there, so
any GCP identity (Cloud Run runtime SA, customer deploys, etc.) can pull
without cross-project IAM.

Regional mirrors of the same image:
  us-docker.pkg.dev/followrabbit-ai-public/images/bq-reverse-proxy
  europe-docker.pkg.dev/followrabbit-ai-public/images/bq-reverse-proxy
  asia-docker.pkg.dev/followrabbit-ai-public/images/bq-reverse-proxy

Pick the mirror closest to your Cloud Run region, or point at a mirror in
your own Artifact Registry.
EOT
  default     = "europe-docker.pkg.dev/followrabbit-ai-public/images/bq-reverse-proxy"
}

variable "image_tag" {
  type        = string
  description = <<EOT
Image tag to deploy. Defaults to "latest" — the newest bq-reverse-proxy
release. Set a specific release tag (e.g. "v0.1.0", see the GitHub
releases / your Rabbit representative) to pin the version and control
upgrades explicitly — recommended for production change management.
EOT
  default     = "latest"
}

# -----------------------------------------------------------------------
# API keys
# -----------------------------------------------------------------------

variable "api_keys" {
  type        = map(string)
  sensitive   = true
  description = <<EOT
Rabbit API keys as one alias => key map. The reserved alias "default" is
the fallback key used when a request carries no `rabbit-api-key` header
and matches no path alias — for a single-key deployment that's the only
entry you need:

  api_keys = { default = var.rabbit_api_key }

Every other alias routes a workload: clients point their BigQuery endpoint
at `https://<proxy-url>/<alias>` and the proxy resolves that alias's key.

  api_keys = {
    default = var.rabbit_api_key
    dbt     = var.rabbit_api_key_dbt
    looker  = var.rabbit_api_key_looker
  }

Aliases must be single path segments and must not collide with reserved
segments (bigquery, upload, batch, discovery, healthz, readyz, metrics).
Key resolution order in the proxy: `rabbit-api-key` header, then path
alias, then the "default" key.

The keys are injected as plain-text env vars, visible in the Cloud Run
revision spec to anyone with run.services.get. Prefer the Secret Manager
path instead: `create_api_keys_secret = true` (module-managed secret) or
`api_keys_secret` (bring your own). Mutually exclusive with both.
EOT
  default     = {}

  validation {
    condition = alltrue([
      for alias, _ in var.api_keys :
      can(regex("^[^/]+$", alias)) && !contains(["bigquery", "upload", "batch", "discovery", "healthz", "readyz", "metrics"], alias)
    ])
    error_message = "Aliases must be single path segments and must not be a reserved segment (bigquery, upload, batch, discovery, healthz, readyz, metrics)."
  }
}

variable "create_api_keys_secret" {
  type        = bool
  description = <<EOT
Create a Secret Manager secret named "<service_name>-api-keys" and inject
the keys from it (env-var-from-secret — keys never appear in the revision
spec or console). The module grants the runtime service account
roles/secretmanager.secretAccessor on it. The secret is created EMPTY: add
the keys as a secret version out-of-band (see the README for the gcloud
command) in the same alias=key format `api_keys` renders to, e.g.
"default=key0,dbt=key1" — the first Cloud Run rollout only succeeds once a
version exists. Requires proxy image >= v0.2.0 (support for the "default"
alias). Mutually exclusive with `api_keys` and `api_keys_secret`.
EOT
  default     = false
}

variable "api_keys_secret" {
  type        = string
  description = <<EOT
Existing Secret Manager secret holding the alias => key mapping in
"default=key0,alias1=key1" format (see `api_keys` for alias semantics),
injected via env-var-from-secret. Use the short secret id for a secret in
`project_id`, or the full "projects/<p>/secrets/<name>" resource name for
a secret in another project. The module does NOT manage IAM on secrets it
doesn't own — grant the runtime service account
roles/secretmanager.secretAccessor on the secret yourself (see README).
Requires proxy image >= v0.2.0. Mutually exclusive with `api_keys` and
`create_api_keys_secret`.
EOT
  default     = null
}

variable "api_keys_secret_version" {
  type        = string
  description = "Secret version to pin when the keys come from Secret Manager. Note: with \"latest\", new versions only take effect on the next revision rollout, not on running instances."
  default     = "latest"
}

variable "optimizer_configs" {
  # `any` rather than map(object): values are passed through as JSON
  # verbatim, and map(any) would force every alias's config to have the
  # same shape.
  type        = any
  description = <<EOT
Per-workload BQ Job Optimizer config, keyed by the same aliases as
`api_keys` (the reserved alias "default" covers root traffic and any alias
without its own entry). Overrides the server-side per-key configuration for
requests going through this deployment — fully self-service, no Rabbit UI
involvement.

Each value is passed to the optimizer as JSON verbatim, so field names use
the optimizer's camelCase contract and new optimizer capabilities need no
module update. Currently accepted fields: `reservationIds` (list),
`statementLevelOverride` (bool). The pricing mode is derived per job
project by the optimizer and cannot be set from this direction. Example:

  optimizer_configs = {
    default = { statementLevelOverride = true }
    dbt     = { reservationIds = ["my-project:EU.my-reservation"] }
  }

Field-level validation happens in the optimizer: an invalid config is
rejected per request (logged on both sides, queries fail open — never
blocked). The config is not secret; it is rendered as a plain env var and
logged by both the proxy and the optimizer for per-request attribution.
Requires proxy image >= v0.2.0.
EOT
  default     = {}

  validation {
    condition     = can(keys(var.optimizer_configs)) && try(alltrue([for _, c in var.optimizer_configs : can(keys(c))]), false) || try(length(var.optimizer_configs) == 0, false)
    error_message = "optimizer_configs must be a map of alias => config object."
  }

  validation {
    condition = try(alltrue([
      for alias, _ in var.optimizer_configs :
      can(regex("^[^/]+$", alias)) && !contains(["bigquery", "upload", "batch", "discovery", "healthz", "readyz", "metrics"], alias)
    ]), true)
    error_message = "Aliases must be single path segments and must not be a reserved segment (bigquery, upload, batch, discovery, healthz, readyz, metrics)."
  }

  validation {
    condition = try(alltrue([
      for _, c in var.optimizer_configs :
      !contains(keys(c), "defaultPricingModeOverride")
    ]), true)
    error_message = "defaultPricingModeOverride cannot be set per proxy route — the optimizer derives the pricing mode per job project."
  }
}

variable "default_api_key" {
  type        = string
  sensitive   = true
  description = <<EOT
DEPRECATED: use `api_keys = { default = "..." }` (or its Secret Manager
variants) instead. Kept for backward compatibility; still works, but new
configuration options land on `api_keys` only. Mutually exclusive with
`api_keys` and the secret variants.
EOT
  default     = null
}

variable "api_key_routes" {
  type        = map(string)
  sensitive   = true
  description = <<EOT
DEPRECATED: use `api_keys` (non-"default" aliases) or its Secret Manager
variants instead. Kept for backward compatibility; still works, but new
configuration options land on `api_keys` only. Mutually exclusive with
`api_keys` and the secret variants.
EOT
  default     = {}

  validation {
    condition = alltrue([
      for alias, _ in var.api_key_routes :
      can(regex("^[^/]+$", alias)) && !contains(["default", "bigquery", "upload", "batch", "discovery", "healthz", "readyz", "metrics"], alias)
    ])
    error_message = "Aliases must be single path segments and must not be a reserved segment (default, bigquery, upload, batch, discovery, healthz, readyz, metrics)."
  }
}

# -----------------------------------------------------------------------
# Secret Manager
# -----------------------------------------------------------------------

variable "secret_locations" {
  type        = list(string)
  description = <<EOT
Regions every Secret Manager secret this module creates is replicated to
(user-managed replication), e.g. ["europe-west3"] or [var.region]. Set this
when your organization requires secrets to be region-bound rather than
globally replicated. The empty default keeps Google-managed automatic
(global) replication.

Module-wide on purpose: it covers the API keys secret
(`create_api_keys_secret = true`) and any further secret the module grows
later, so residency is configured once rather than per secret. It does NOT
touch secrets you bring yourself via `api_keys_secret` — those are
replicated however you created them.

Replication is immutable in Secret Manager: changing this on an existing
secret makes Terraform destroy and recreate it, which deletes every secret
version with it. Re-add the keys afterwards (see the README).
EOT
  default     = []
}

# -----------------------------------------------------------------------
# Runtime knobs
# -----------------------------------------------------------------------

variable "service_name" {
  type        = string
  description = "Cloud Run service name."
  default     = "bq-reverse-proxy"
}

variable "service_account_email" {
  type        = string
  description = <<EOT
Service account email the proxy runs as. Leave null to have the module create
one named <service_name>-sa@<project>.iam.gserviceaccount.com.
EOT
  default     = null
}

variable "min_instances" {
  type        = number
  description = "Cloud Run minimum instance count. >=1 avoids cold-start latency on the hot path."
  default     = 1
}

variable "max_instances" {
  type        = number
  description = "Cloud Run maximum instance count."
  default     = 50
}

variable "cpu" {
  type        = string
  description = "CPU per instance (e.g. \"1\", \"2\")."
  default     = "1"
}

variable "memory" {
  type        = string
  description = "Memory per instance (e.g. \"512Mi\", \"1Gi\")."
  default     = "512Mi"
}

variable "allow_unauthenticated" {
  type        = bool
  description = <<EOT
Grant roles/run.invoker to allUsers. The proxy itself does not care about
the caller identity (it forwards BigQuery Authorization: Bearer as-is), and
the official BigQuery client SDKs cannot satisfy a Cloud Run IAM gate anyway
because they send OAuth2 access tokens scoped to BigQuery, not ID tokens
audience-bound to the proxy URL. The recommended secure setup is:

    allow_unauthenticated = true
    ingress               = "INGRESS_TRAFFIC_INTERNAL_ONLY"

so the URL is only reachable from the same VPC SC perimeter / Cloud Run
instances in the same project — no public exposure, no IAM friction.
Setting allow_unauthenticated=false with SDK callers will return HTML 401
from the Cloud Run gate before the request reaches the proxy.
EOT
  default     = false
}

variable "ingress" {
  type        = string
  description = <<EOT
Cloud Run ingress setting. One of:
  - INGRESS_TRAFFIC_ALL                              (default; reachable from public internet)
  - INGRESS_TRAFFIC_INTERNAL_ONLY                    (only same-project / VPC SC perimeter / connected Cloud Run)
  - INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER           (internal + Google Cloud Load Balancing only)

Pair with allow_unauthenticated=true for the SDK-friendly secure setup.
EOT
  default     = "INGRESS_TRAFFIC_ALL"

  validation {
    condition = contains([
      "INGRESS_TRAFFIC_ALL",
      "INGRESS_TRAFFIC_INTERNAL_ONLY",
      "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER",
    ], var.ingress)
    error_message = "ingress must be one of INGRESS_TRAFFIC_ALL | INGRESS_TRAFFIC_INTERNAL_ONLY | INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  }
}

variable "default_uri_disabled" {
  type        = bool
  description = <<EOT
Disable public resolution of the Cloud Run default `*.run.app` URI, so the
service can only be reached through an entry point you control (a load
balancer, or another internal address). Independent of `ingress`: ingress
controls where traffic may come from, this removes the built-in hostname.

The `service_url` output stays populated with the (now unresolvable) default
URI — point clients at your own endpoint instead.

Requires google provider >= 7.7.0 (the release that promoted this field out
of beta), which is this module's minimum anyway.
EOT
  default     = false
}

variable "invoker_members" {
  type        = list(string)
  description = <<EOT
IAM principals (serviceAccount:..., user:..., group:...) that should be
granted roles/run.invoker. Ignored when allow_unauthenticated=true.
EOT
  default     = []
}

variable "bq_api_target_url" {
  type        = string
  description = "Upstream BigQuery base URL. Do not change unless you know why."
  default     = "https://bigquery.googleapis.com"
}

variable "log_level" {
  type        = string
  description = "debug | info | warn | error."
  default     = "info"

  validation {
    condition     = contains(["debug", "info", "warn", "error"], var.log_level)
    error_message = "log_level must be one of: debug, info, warn, error."
  }
}

variable "max_body_bytes" {
  type        = number
  description = "Maximum request body the proxy will buffer for optimization. Bodies above this cap are forwarded untouched (fail-open)."
  default     = 1048576 # 1 MiB
}

variable "bq_job_optimizer_timeout" {
  type        = string
  description = "Per-call bq-job-optimizer timeout as a Go duration string (e.g. \"2s\")."
  default     = "2s"
}

variable "request_timeout" {
  type        = string
  description = "Upstream BigQuery request timeout as a Go duration string."
  default     = "10m"
}

variable "vpc_connector" {
  type        = string
  description = "Fully-qualified VPC access connector ID. Leave null for public egress."
  default     = null
}

variable "vpc_egress" {
  type        = string
  description = "VPC egress setting: ALL_TRAFFIC | PRIVATE_RANGES_ONLY."
  default     = "PRIVATE_RANGES_ONLY"
}

variable "labels" {
  type        = map(string)
  description = "Labels applied to every resource this module creates."
  default     = {}
}

variable "extra_env" {
  type        = map(string)
  description = "Extra environment variables to set on the Cloud Run container (e.g. custom OTEL config)."
  default     = {}
}
