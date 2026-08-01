output "service_name" {
  description = "Cloud Run service name."
  value       = google_cloud_run_v2_service.proxy.name
}

output "service_url" {
  description = "HTTPS URL of the proxy. Point BigQuery clients' root URL at this (replacing https://bigquery.googleapis.com)."
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

output "default_api_key_secret_id" {
  description = "Secret Manager secret id holding the default API key (only when create_default_api_key_secret = true). Add the key with: gcloud secrets versions add <this> --data-file=- --project <project_id>"
  value       = var.create_default_api_key_secret ? google_secret_manager_secret.default_api_key[0].secret_id : null
}

output "api_key_routes_secret_id" {
  description = "Secret Manager secret id holding the API key routes mapping (only when create_api_key_routes_secret = true). Add the mapping with: gcloud secrets versions add <this> --data-file=- --project <project_id>"
  value       = var.create_api_key_routes_secret ? google_secret_manager_secret.api_key_routes[0].secret_id : null
}

output "version" {
  description = "Version string baked into this module copy (useful for asserting the right pin was consumed)."
  value       = local.version
}
