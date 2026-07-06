# Version of the proxy release this copy of the deployment package was
# written against. The deployed image tag is controlled by var.image_tag
# ("latest" by default; set a release tag like "v0.1.0" to pin) — this
# literal is only the fallback when image_tag is set to null, and it feeds
# the `version` label and output for provenance.

locals {
  version = "v0.1.0"
}
