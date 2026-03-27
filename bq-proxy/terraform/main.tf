terraform {
  required_version = ">= 1.3"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# ─── Service Account ────────────────────────────────────────────────────────────

resource "google_service_account" "bq_proxy" {
  account_id   = "${var.service_name}-sa"
  display_name = "BQ Proxy Service Account"
}

# ─── Cloud Run Service ──────────────────────────────────────────────────────────

resource "google_cloud_run_v2_service" "bq_proxy" {
  name     = var.service_name
  location = var.region

  template {
    service_account = google_service_account.bq_proxy.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    timeout                          = "${var.request_timeout}s"
    max_instance_request_concurrency = 100

    containers {
      image = var.image

      ports {
        container_port = var.port
      }

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
        cpu_idle = true
      }

      env {
        name  = "PORT"
        value = tostring(var.port)
      }
      env {
        name  = "BQ_TARGET_URL"
        value = var.bq_target_url
      }
      env {
        name  = "REQUEST_TIMEOUT"
        value = tostring(var.request_timeout)
      }
      env {
        name  = "LOG_LEVEL"
        value = var.log_level
      }
      env {
        name  = "RABBIT_API_KEY"
        value = var.rabbit_api_key
      }
      env {
        name  = "RABBIT_API_BASE_URL"
        value = var.rabbit_api_base_url
      }
      env {
        name  = "RABBIT_API_TIMEOUT"
        value = tostring(var.rabbit_api_timeout)
      }
      env {
        name  = "DEFAULT_PRICING_MODE"
        value = var.default_pricing_mode
      }
      env {
        name  = "RESERVATION_IDS"
        value = join(",", var.reservation_ids)
      }

      startup_probe {
        http_get {
          path = "/healthz"
          port = var.port
        }
        initial_delay_seconds = 0
        period_seconds        = 2
        failure_threshold     = 5
        timeout_seconds       = 2
      }

      liveness_probe {
        http_get {
          path = "/healthz"
          port = var.port
        }
        initial_delay_seconds = 10
        period_seconds        = 15
        failure_threshold     = 3
        timeout_seconds       = 5
      }
    }
  }
}

# ─── IAM: Allow Unauthenticated Access ──────────────────────────────────────────

resource "google_cloud_run_v2_service_iam_member" "public_access" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.bq_proxy.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}
