variable "project_id" {
  description = "Default GCP project ID"
  type        = string

  default     = "[TBD]"
}

variable "target_buckets" {
  description = "Bucket names to turn on insights"
  type        = list(string)

  default = ["[TBD]"]
}
