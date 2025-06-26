resource "google_storage_bucket_iam_member" "usage_log_agent_object_creators" {
  for_each = data.google_storage_bucket.target_buckets
  depends_on = [google_storage_bucket.report_buckets]
  bucket = google_storage_bucket.report_buckets[each.key].name
  role   = "roles/storage.objectCreator"
  member = "group:cloud-storage-analytics@google.com"
}

resource "null_resource" "bucket_usage_logs" {
  depends_on = [google_storage_bucket_iam_member.usage_log_agent_object_creators]
  for_each = data.google_storage_bucket.target_buckets

  provisioner "local-exec" {
    command = <<EOT
      gcloud storage buckets update gs://${each.key} \
        --log-bucket=${google_storage_bucket.report_buckets[each.key].name} \
        --log-object-prefix=logs/
    EOT
  }
}
