terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 8.0"
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

  # Secret Manager sources for DEFAULT_API_KEY / API_KEY_ROUTES: the
  # module-created secret's id, a caller-supplied secret reference, or
  # null (plain env / disabled).
  api_key_secret        = var.create_default_api_key_secret ? google_secret_manager_secret.default_api_key[0].secret_id : var.default_api_key_secret
  api_key_routes_secret = var.create_api_key_routes_secret ? google_secret_manager_secret.api_key_routes[0].secret_id : var.api_key_routes_secret

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
# Secret Manager secrets for the API keys (optional)
# -----------------------------------------------------------------------

resource "google_secret_manager_secret" "default_api_key" {
  count     = var.create_default_api_key_secret ? 1 : 0
  project   = var.project_id
  secret_id = "${var.service_name}-default-api-key"
  labels    = local.base_labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "default_api_key_accessor" {
  count     = var.create_default_api_key_secret ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.default_api_key[0].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = local.effective_sa_member
}

resource "google_secret_manager_secret" "api_key_routes" {
  count     = var.create_api_key_routes_secret ? 1 : 0
  project   = var.project_id
  secret_id = "${var.service_name}-api-key-routes"
  labels    = local.base_labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_iam_member" "api_key_routes_accessor" {
  count     = var.create_api_key_routes_secret ? 1 : 0
  project   = var.project_id
  secret_id = google_secret_manager_secret.api_key_routes[0].secret_id
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

  ingress             = var.ingress
  deletion_protection = false

  template {
    service_account = local.effective_sa_email
    labels          = local.base_labels

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    # VPC connector (optional).
    dynamic "vpc_access" {
      for_each = var.vpc_connector == null ? [] : [1]
      content {
        connector = var.vpc_connector
        egress    = var.vpc_egress
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

      # Optional: DEFAULT_API_KEY is only set when the caller supplies a
      # non-null value. The proxy reads it at startup and uses it as the
      # fallback key for requests that omit `rabbit-api-key`.
      dynamic "env" {
        # nonsensitive: comparisons against a sensitive var are themselves
        # sensitive-marked, and dynamic for_each rejects sensitive values.
        # Only the presence/absence is unmarked here, never the key itself.
        for_each = nonsensitive(var.default_api_key == null) ? [] : [1]
        content {
          name  = "DEFAULT_API_KEY"
          value = var.default_api_key
        }
      }

      # Optional: DEFAULT_API_KEY sourced from Secret Manager instead of a
      # plain value. Cloud Run resolves the secret at instance startup; the
      # key never appears in the revision spec.
      dynamic "env" {
        for_each = local.api_key_secret == null ? [] : [1]
        content {
          name = "DEFAULT_API_KEY"
          value_source {
            secret_key_ref {
              secret  = local.api_key_secret
              version = var.default_api_key_secret_version
            }
          }
        }
      }

      # Optional: API_KEY_ROUTES sourced from Secret Manager. The secret
      # value uses the same "alias1=key1,alias2=key2" format the plain
      # variable renders to.
      dynamic "env" {
        for_each = local.api_key_routes_secret == null ? [] : [1]
        content {
          name = "API_KEY_ROUTES"
          value_source {
            secret_key_ref {
              secret  = local.api_key_routes_secret
              version = var.api_key_routes_secret_version
            }
          }
        }
      }

      # Optional: API_KEY_ROUTES maps URL path aliases to API keys for
      # clients that cannot send the `rabbit-api-key` header. Rendered as
      # "alias1=key1,alias2=key2".
      dynamic "env" {
        for_each = nonsensitive(length(var.api_key_routes) == 0) ? [] : [1]
        content {
          name  = "API_KEY_ROUTES"
          value = join(",", [for alias, key in var.api_key_routes : "${alias}=${key}"])
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

  # The revision resolves the secrets at startup — make sure the accessor
  # grants exist before the rollout, not in parallel with it.
  depends_on = [
    google_secret_manager_secret_iam_member.default_api_key_accessor,
    google_secret_manager_secret_iam_member.api_key_routes_accessor,
  ]

  lifecycle {
    precondition {
      condition = length([for set in [
        nonsensitive(var.default_api_key != null),
        var.create_default_api_key_secret,
        var.default_api_key_secret != null,
      ] : set if set]) <= 1
      error_message = "Set at most one of default_api_key, create_default_api_key_secret, and default_api_key_secret — they are mutually exclusive sources for DEFAULT_API_KEY."
    }

    precondition {
      condition = length([for set in [
        nonsensitive(length(var.api_key_routes) > 0),
        var.create_api_key_routes_secret,
        var.api_key_routes_secret != null,
      ] : set if set]) <= 1
      error_message = "Set at most one of api_key_routes, create_api_key_routes_secret, and api_key_routes_secret — they are mutually exclusive sources for API_KEY_ROUTES."
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
