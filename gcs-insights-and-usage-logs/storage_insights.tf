locals {
  # Extract the project ID for each source bucket and remove duplicates
  projects = toset(distinct([for bucket in data.google_storage_bucket.target_buckets : bucket.project]))
}

resource "google_project_service" "storage_insights" {
  for_each = local.projects
  service = "storageinsights.googleapis.com"
  project = each.value
}

resource "google_project_service_identity" "storage_insights_sa" {
  for_each = local.projects
  depends_on = [google_project_service.storage_insights]
  provider = google-beta

  project = each.value
  service = "storageinsights.googleapis.com"
}

resource "google_storage_bucket_iam_member" "admin_agent_object_creators" {
  for_each = data.google_storage_bucket.target_buckets
  depends_on = [google_project_service_identity.storage_insights_sa]
  bucket = google_storage_bucket.report_buckets[each.key].name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:service-${google_storage_bucket.report_buckets[each.key].project_number}@gcp-sa-storageinsights.iam.gserviceaccount.com"
}

resource "google_storage_bucket_iam_member" "admin_agent_insights_collectors" {
  for_each = data.google_storage_bucket.target_buckets
  depends_on = [google_project_service_identity.storage_insights_sa]
  bucket = each.key
  role   = "roles/storage.insightsCollectorService"
  member = "serviceAccount:service-${google_storage_bucket.report_buckets[each.key].project_number}@gcp-sa-storageinsights.iam.gserviceaccount.com"
}

resource "google_storage_insights_report_config" "configs" {
  for_each = data.google_storage_bucket.target_buckets
  depends_on = [google_storage_bucket_iam_member.admin_agent_insights_collectors]
  display_name = "Insights Reports for Rabbit"
  project = each.value.project
  location = lower(each.value.location)
  frequency_options {
    frequency = "WEEKLY"
    start_date {
      day = formatdate("D", timeadd(timestamp(), "24h"))
      month = formatdate("M", timeadd(timestamp(), "24h"))
      year = formatdate("YYYY", timeadd(timestamp(), "24h"))
    }
    end_date {
      day = 31
      month = 12
      year = 2999
    }
  }
  parquet_options {
  }

  object_metadata_report_options {
    metadata_fields = ["project", "bucket", "name", "location", "size", "timeCreated", "timeDeleted", "updated", "storageClass", "etag", "retentionExpirationTime",
      "crc32c", "md5Hash", "generation", "metageneration", "contentType", "contentEncoding", "timeStorageClassUpdated"]
    storage_filters {
      bucket = each.value.name
    }
    storage_destination_options {
      bucket = google_storage_bucket.report_buckets[each.key].name
      destination_path = "insights/"
    }
  }

  lifecycle {
    ignore_changes = [
      frequency_options[0].start_date,
    ]
  }
}
