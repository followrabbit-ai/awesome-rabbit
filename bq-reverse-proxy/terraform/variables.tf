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
# API key — fallback only
# -----------------------------------------------------------------------

variable "default_api_key" {
  type        = string
  sensitive   = true
  description = <<EOT
Default Rabbit API key used when a client request does not carry the
`rabbit-api-key` header. Leave null to disable — unauthenticated clients
will then bypass the optimizer entirely.

The caller is responsible for sourcing the secret (e.g. via a
google_secret_manager_secret_version data source in the root module) and
passing the plain string here. This module does not manage Secret Manager.
EOT
  default     = null
}

variable "api_key_routes" {
  type        = map(string)
  sensitive   = true
  description = <<EOT
Map of URL path alias => Rabbit API key, for running multiple workloads
(each with its own API key and optimization settings) through one proxy
deployment. Clients that cannot send the `rabbit-api-key` header point
their BigQuery endpoint at `https://<proxy-url>/<alias>` and the proxy
resolves the key from the alias. Example:

  api_key_routes = {
    dbt    = var.rabbit_api_key_dbt
    looker = var.rabbit_api_key_looker
  }

Aliases must be single path segments and must not collide with reserved
segments (bigquery, upload, batch, discovery, healthz, readyz, metrics).
Key resolution order in the proxy: `rabbit-api-key` header, then path
alias, then `default_api_key`.
EOT
  default     = {}

  validation {
    condition = alltrue([
      for alias, _ in var.api_key_routes :
      can(regex("^[^/]+$", alias)) && !contains(["bigquery", "upload", "batch", "discovery", "healthz", "readyz", "metrics"], alias)
    ])
    error_message = "Aliases must be single path segments and must not be a reserved segment (bigquery, upload, batch, discovery, healthz, readyz, metrics)."
  }
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
    ingress               = "INGRESS_TRAFFIC_INTERNAL"

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
  - INGRESS_TRAFFIC_INTERNAL                         (only same-project / VPC SC perimeter / connected Cloud Run)
  - INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER           (internal + Google Cloud Load Balancing only)

Pair with allow_unauthenticated=true for the SDK-friendly secure setup.
EOT
  default     = "INGRESS_TRAFFIC_ALL"

  validation {
    condition = contains([
      "INGRESS_TRAFFIC_ALL",
      "INGRESS_TRAFFIC_INTERNAL",
      "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER",
    ], var.ingress)
    error_message = "ingress must be one of INGRESS_TRAFFIC_ALL | INGRESS_TRAFFIC_INTERNAL | INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"
  }
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
