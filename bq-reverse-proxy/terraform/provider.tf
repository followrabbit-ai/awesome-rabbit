# awesome-rabbit-only file — not part of the synced module. The synced *.tf
# files form a provider-less module; this makes the directory usable as a
# standalone root configuration.
provider "google" {
  project = var.project_id
  region  = var.region
}
