output "service_name" {
  description = "Cloud Run service name."
  value       = google_cloud_run_v2_service.proxy.name
}

output "service_url" {
  description = "HTTPS URL of the proxy. Point BigQuery clients' root URL at this (replacing https://bigquery.googleapis.com). Empty when default_uri_disabled = true — Cloud Run reports no URI for the service then, so use your own endpoint instead."
  value       = google_cloud_run_v2_service.proxy.uri
}

output "service_account_email" {
  description = "Service account the proxy Cloud Run service runs as."
  value       = local.effective_sa_email
}

output "image" {
  description = "Fully-qualified image reference the Cloud Run revision was deployed with."
  value       = local.resolved_image
}

output "api_keys_secret_id" {
  description = "Secret Manager secret id holding the API keys (only when create_api_keys_secret = true). Add the keys with: gcloud secrets versions add <this> --data-file=- --project <project_id>"
  value       = var.create_api_keys_secret ? google_secret_manager_secret.api_keys[0].secret_id : null
}

output "version" {
  description = "Version string baked into this module copy (useful for asserting the right pin was consumed)."
  value       = local.version
}
