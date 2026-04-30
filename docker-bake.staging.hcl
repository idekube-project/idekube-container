# Staging override file. Layered after docker-bake.hcl:
#   docker buildx bake -f docker-bake.hcl -f docker-bake.staging.hcl <group>
#
# - STAGING_POSTFIX: appended to every tag, after the lineup postfix.
# - VERSION: defaults to "edge" for local invocations; CI sets it to the short
#   commit SHA via the VERSION env var.

variable "STAGING_POSTFIX" { default = "-staging" }
variable "VERSION"         { default = "edge" }
