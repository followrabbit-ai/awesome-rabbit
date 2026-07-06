# Version of both the Terraform module shape and the Docker image it pins.
# The version literal selects the image tag pulled at deploy time — see
# main.tf where local.resolved_image_tag = coalesce(var.image_tag, local.version).
#
# This module reaches consumers two ways:
#
#   * Rabbit-internal: pin the Git source to a tag —
#       source = "git::https://github.com/followrabbit-ai/bq-reverse-proxy.git//deploy/terraform?ref=v1.2.3"
#     The source pin chooses the file layout AND the image tag at once.
#
#   * Customers: a manually-maintained vendored copy in the public
#     awesome-rabbit repo (bq-reverse-proxy/terraform/) that overrides
#     image_tag to "latest", so customers always deploy the newest release
#     without needing access to this repository. If a release changes this
#     module's shape (env vars, probes, inputs), update that copy as part
#     of the release.
#
# Keep every file in this directory customer-appropriate: it may be
# republished in the public package.

locals {
  version = "v0.1.0" # x-release-please-version
}
