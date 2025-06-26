data "google_storage_bucket" "target_buckets" {
  for_each = toset(var.target_buckets)
  name     = each.key
}

resource "google_storage_bucket" "report_buckets" {
  for_each = data.google_storage_bucket.target_buckets

  name          = "rbt-${replace(each.key,".", "-")}-rpt"
  location      = each.value.location
  project       = each.value.project

  uniform_bucket_level_access = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 10
    }
  }
}
