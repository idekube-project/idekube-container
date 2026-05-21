# Staging override file. Layered after docker-bake.hcl:
#   docker buildx bake -f docker-bake.hcl -f docker-bake.staging.hcl <group>
#
# - STAGING_POSTFIX: appended to every tag, after the lineup postfix.
# - VERSION: defaults to "edge" for local invocations. CI (publish.yml) sets it
#   via the VERSION env var: the release tag on prerelease events, or the short
#   commit SHA on workflow_dispatch.

variable "STAGING_POSTFIX" { default = "-staging" }
variable "VERSION"         { default = "edge" }
