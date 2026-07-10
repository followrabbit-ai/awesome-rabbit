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
        for_each = var.default_api_key == null ? [] : [1]
        content {
          name  = "DEFAULT_API_KEY"
          value = var.default_api_key
        }
      }

      # Optional: API_KEY_ROUTES maps URL path aliases to API keys for
      # clients that cannot send the `rabbit-api-key` header. Rendered as
      # "alias1=key1,alias2=key2".
      dynamic "env" {
        for_each = length(var.api_key_routes) == 0 ? [] : [1]
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
