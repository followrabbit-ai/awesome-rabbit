output "service_url" {
  description = "URL of the deployed BQ Proxy Cloud Run service"
  value       = google_cloud_run_v2_service.bq_proxy.uri
}

output "service_name" {
  description = "Name of the Cloud Run service"
  value       = google_cloud_run_v2_service.bq_proxy.name
}

output "service_account_email" {
  description = "Email of the service account used by the proxy"
  value       = google_service_account.bq_proxy.email
}
