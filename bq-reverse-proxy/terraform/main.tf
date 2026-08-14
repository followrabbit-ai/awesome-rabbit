terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source = "hashicorp/google"
      # >= 7.7.0: first GA release with default_uri_disabled on
      # google_cloud_run_v2_service (beta-only before that).
      version = ">= 7.7.0, < 8.0"
    }
  }
}

locals {
  # The image tag comes from var.image_tag ("latest" by default; set a
  # release tag like "v0.1.0" to pin). local.version is only the fallback
  # when image_tag is explicitly set to null.
  resolved_image_tag = coalesce(var.image_tag, local.version)
  resolved_image     = "${var.image_registry}:${local.resolved_image_tag}"

  # If the caller didn't supply an SA email, we create one.
  create_sa           = var.service_account_email == null
  effective_sa_email  = local.create_sa ? google_service_account.proxy[0].email : var.service_account_email
  effective_sa_member = "serviceAccount:${local.effective_sa_email}"

  base_labels = merge({
    "managed-by" = "bq-reverse-proxy"
    "version"    = replace(local.version, ".", "-")
  }, var.labels)

  # Plain-text key sources: the unified api_keys map ("default" alias =
  # fallback key) or the deprecated default_api_key / api_key_routes pair.
  # Split in Terraform so plain mode works with any proxy image version.
  plain_default_key = var.default_api_key != null ? var.default_api_key : lookup(var.api_keys, "default", null)
  plain_routes      = length(var.api_key_routes) > 0 ? var.api_key_routes : { for alias, key in var.api_keys : alias => key if alias != "default" }

  # Secret Manager source for the whole key map: the module-created
  # secret's id, a caller-supplied secret reference, or null (plain env).
  api_keys_secret = var.create_api_keys_secret ? google_secret_manager_secret.api_keys[0].secret_id : var.api_keys_secret

  # Replication mode for every secret the module creates: user-managed (one
  # replica per var.secret_locations entry) when locations are pinned,
  # Google-managed automatic/global otherwise.
  secret_user_managed = length(var.secret_locations) > 0

  # Per-alias optimizer configs, passed through verbatim — the map values
  # already use the optimizer's camelCase field names.
  optimizer_configs_env = length(var.optimizer_configs) == 0 ? null : jsonencode(var.optimizer_configs)

  base_env = {
    # PORT is reserved by Cloud Run v2 — it is automatically set to match
    # the container port and cannot be overridden here.
    BQ_API_TARGET_URL        = var.bq_api_target_url
    BQ_JOB_OPTIMIZER_URL     = var.bq_job_optimizer_url
    BQ_JOB_OPTIMIZER_TIMEOUT = var.bq_job_optimizer_timeout
    REQUEST_TIMEOUT          = var.request_timeout
    MAX_BODY_BYTES           = tostring(var.max_body_bytes)
    LOG_LEVEL                = var.log_level
  }
}

# -----------------------------------------------------------------------
# Service account (optional — only if the caller didn't bring their own)
# -----------------------------------------------------------------------

resource "google_service_account" "proxy" {
  count        = local.create_sa ? 1 : 0
  project      = var.project_id
  account_id   = "${var.service_name}-sa"
  display_name = "SA for ${var.service_name} Cloud Run service"
  description  = "Managed by the bq-reverse-proxy Terraform module."
}

# -----------------------------------------------------------------------
# Secret Manager secret for the API keys (optional)
# -----------------------------------------------------------------------

resource "google_secret_manager_secret" "api_keys" {
  count     = var.create_api_keys_secret ? 1 : 0
  project   = var.project_id
  secret_id = "${var.service_name}-api-keys"
  labels    = local.base_labels

  # Automatic (global) replication unless var.secret_locations pins regions —
  # some organizations require secrets to be region-bound for data residency.
  # Every secret this module creates uses this same block.
  replication {
    dynamic "auto" {
      for_each = local.secret_user_managed ? [] : [1]
      content {}
    }

    dynamic "user_managed" {
      for_each = local.secret_user_managed ? [1] : []
      content {
        dynamic "replicas" {
          for_each = var.secret_locations
          content {
            location = replicas.value
          }
        }
      }
    }
  }
}

resource "google_secret_manager_secret_iam_member" "api_keys_accessor" {
  count     = var.create_api_keys_secret ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.api_keys[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.effective_sa_member
}

# -----------------------------------------------------------------------
# Cloud Run v2 service
# -----------------------------------------------------------------------

resource "google_cloud_run_v2_service" "proxy" {
  project  = var.project_id
  location = var.region
  name     = var.service_name
  labels   = local.base_labels

  ingress              = var.ingress
  default_uri_disabled = var.default_uri_disabled
  deletion_protection  = false

  template {
    service_account = local.effective_sa_email
    labels          = local.base_labels

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # VPC egress (optional) — either a connector (var.vpc_connector) or
    # Direct VPC egress (var.vpc_network + var.vpc_subnetwork). Direct is
    # preferred: no connector VMs to size or pay for, and it is what gives
    # the service a fixed NAT egress IP when the subnet's Private Google
    # Access is off.
    dynamic "vpc_access" {
      for_each = var.vpc_connector == null && var.vpc_network == null ? [] : [1]
      content {
        connector = var.vpc_connector
        egress    = var.vpc_egress

        dynamic "network_interfaces" {
          for_each = var.vpc_network == null ? [] : [1]
          content {
            network    = var.vpc_network
            subnetwork = var.vpc_subnetwork
          }
        }
      }
    }

    containers {
      image = local.resolved_image

      ports {
        container_port = 8080
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      startup_probe {
        http_get {
          path = "/readyz"
        }
        initial_delay_seconds = 2
        period_seconds        = 5
        timeout_seconds       = 3
        failure_threshold     = 6
      }

      liveness_probe {
        http_get {
          path = "/healthz"
        }
        period_seconds    = 30
        timeout_seconds   = 3
        failure_threshold = 3
      }

      # Base env (static).
      dynamic "env" {
        for_each = local.base_env
        content {
          name  = env.key
          value = env.value
        }
      }

      # Caller-supplied extras.
      dynamic "env" {
        for_each = var.extra_env
        content {
          name  = env.key
          value = env.value
        }
      }

      # Optional: fallback API key as a plain env var (from api_keys'
      # "default" alias or the deprecated default_api_key variable).
      dynamic "env" {
        # nonsensitive: comparisons against a sensitive value are themselves
        # sensitive-marked, and dynamic for_each rejects sensitive values.
        # Only the presence/absence is unmarked here, never the key itself.
        for_each = nonsensitive(local.plain_default_key == null) ? [] : [1]
        content {
          name  = "DEFAULT_API_KEY"
          value = local.plain_default_key
        }
      }

      # Optional: path-alias route keys as a plain env var, rendered as
      # "alias1=key1,alias2=key2".
      dynamic "env" {
        for_each = nonsensitive(length(local.plain_routes) == 0) ? [] : [1]
        content {
          name  = "API_KEY_ROUTES"
          value = join(",", [for alias, key in local.plain_routes : "${alias}=${key}"])
        }
      }

      # Optional: per-workload optimizer configs. Plain env — the config is
      # not sensitive and both proxy and optimizer log it for attribution.
      dynamic "env" {
        for_each = local.optimizer_configs_env == null ? [] : [1]
        content {
          name  = "OPTIMIZER_CONFIGS"
          value = local.optimizer_configs_env
        }
      }

      # Optional: the whole key map sourced from Secret Manager. The secret
      # value uses the same format api_keys renders to, with the "default"
      # alias carrying the fallback key ("default=key0,dbt=key1" — needs
      # proxy image >= v0.2.0). Cloud Run resolves the secret at instance
      # startup; keys never appear in the revision spec.
      dynamic "env" {
        for_each = local.api_keys_secret == null ? [] : [1]
        content {
          name = "API_KEY_ROUTES"
          value_source {
            secret_key_ref {
              secret  = local.api_keys_secret
              version = var.api_keys_secret_version
            }
          }
        }
      }
    }
  }

  # Route 100% of traffic to the latest revision. If you need blue/green,
  # fork this module and wire named revisions.
  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  # The revision resolves the secret at startup — make sure the accessor
  # grant exists before the rollout, not in parallel with it.
  depends_on = [google_secret_manager_secret_iam_member.api_keys_accessor]

  lifecycle {
    precondition {
      condition = length([for set in [
        nonsensitive(length(var.api_keys) > 0),
        var.create_api_keys_secret,
        var.api_keys_secret != null,
        nonsensitive(var.default_api_key != null || length(var.api_key_routes) > 0),
      ] : set if set]) <= 1
      error_message = "Configure the API keys through exactly one mechanism: api_keys, create_api_keys_secret, api_keys_secret, or the deprecated default_api_key/api_key_routes pair."
    }

    # Cloud Run rejects these combinations with an opaque API error; catch
    # them at plan time instead.
    precondition {
      condition     = var.vpc_network == null || var.vpc_subnetwork != null
      error_message = "vpc_subnetwork is required when vpc_network is set — Direct VPC egress needs both."
    }

    precondition {
      condition     = var.vpc_connector == null || var.vpc_network == null
      error_message = "Set either vpc_connector or vpc_network, not both — a service uses one egress mechanism."
    }
  }
}

# -----------------------------------------------------------------------
# Invoker IAM
# -----------------------------------------------------------------------

resource "google_cloud_run_v2_service_iam_member" "public_invoker" {
  count    = var.allow_unauthenticated ? 1 : 0
  project  = google_cloud_run_v2_service.proxy.project
  location = google_cloud_run_v2_service.proxy.location
  name     = google_cloud_run_v2_service.proxy.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_cloud_run_v2_service_iam_member" "invokers" {
  for_each = var.allow_unauthenticated ? toset([]) : toset(var.invoker_members)
  project  = google_cloud_run_v2_service.proxy.project
  location = google_cloud_run_v2_service.proxy.location
  name     = google_cloud_run_v2_service.proxy.name
  role     = "roles/run.invoker"
  member   = each.value
}
