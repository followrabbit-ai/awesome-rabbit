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

output "version" {
  description = "Version string baked into this module copy (useful for asserting the right pin was consumed)."
  value       = local.version
}
