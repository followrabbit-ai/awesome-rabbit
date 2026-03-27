variable "project_id" {
  description = "GCP project ID where the BQ Proxy will be deployed"
  type        = string
}

variable "region" {
  description = "GCP region for the Cloud Run service (e.g. us-central1, europe-west1, asia-southeast1)"
  type        = string
}

variable "image" {
  description = "Container image for the BQ Proxy. Use the regional image closest to your BigQuery datasets."
  type        = string
  default     = "us-docker.pkg.dev/rbt-prod-app-eu/rbt-bq-proxy/bq-proxy:latest"
}

variable "rabbit_api_key" {
  description = "API key provided by Rabbit for the BQ Job Optimizer. Leave empty to run in pass-through mode."
  type        = string
  sensitive   = true
  default     = ""
}

variable "default_pricing_mode" {
  description = "Default pricing mode for job optimization: 'on_demand' or 'slot_based'"
  type        = string
  default     = "on_demand"

  validation {
    condition     = contains(["on_demand", "slot_based"], var.default_pricing_mode)
    error_message = "default_pricing_mode must be 'on_demand' or 'slot_based'."
  }
}

variable "reservation_ids" {
  description = "List of BigQuery reservation IDs to consider for optimization"
  type        = list(string)
  default     = []
}

variable "service_name" {
  description = "Name of the Cloud Run service"
  type        = string
  default     = "bq-proxy"
}

variable "min_instances" {
  description = "Minimum number of Cloud Run instances (set to 1+ to avoid cold starts)"
  type        = number
  default     = 1
}

variable "max_instances" {
  description = "Maximum number of Cloud Run instances"
  type        = number
  default     = 20
}

variable "cpu" {
  description = "CPU allocation per instance (e.g. '2' for 2 vCPUs)"
  type        = string
  default     = "2"
}

variable "memory" {
  description = "Memory allocation per instance (e.g. '512Mi', '1Gi')"
  type        = string
  default     = "512Mi"
}

variable "log_level" {
  description = "Log verbosity: debug, info, warn, error"
  type        = string
  default     = "info"
}

variable "port" {
  description = "HTTP listen port for the proxy container"
  type        = number
  default     = 8080
}

variable "bq_target_url" {
  description = "Upstream BigQuery API URL"
  type        = string
  default     = "https://bigquery.googleapis.com"
}

variable "request_timeout" {
  description = "Per-request timeout in seconds"
  type        = number
  default     = 600
}

variable "rabbit_api_base_url" {
  description = "Base URL for the Rabbit BQ Job Optimizer API"
  type        = string
  default     = "https://api.followrabbit.ai/bq-job-optimizer"
}

variable "rabbit_api_timeout" {
  description = "Timeout in seconds for Rabbit API calls"
  type        = number
  default     = 5
}
