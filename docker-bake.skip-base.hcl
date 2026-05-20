# Skip-base override file. Layered after docker-bake.hcl to replace target:
# dependencies with pre-built :stable images from the registry, avoiding a
# full base-image rebuild.
#
#   docker buildx bake -f docker-bake.hcl -f docker-bake.staging.hcl \
#                      -f docker-bake.skip-base.hcl <target>
#
# Env vars:
#   STABLE_TAG         — universal base tag (default: stable)
#   STABLE_TAG_ASCEND  — ascend base tag (default: STABLE_TAG-ascend)

variable "STABLE_TAG"        { default = "stable" }
variable "STABLE_TAG_ASCEND" { default = "" }

# --- featured derivatives (universal) ---------------------------------------

target "featured-speit" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured-base:${STABLE_TAG}"
  }
}

target "featured-speit-ai-universal" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured-base:${STABLE_TAG}"
  }
}

target "featured-dind" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured-base:${STABLE_TAG}"
  }
}

target "featured-kathara" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured:dind-${STABLE_TAG}"
  }
}

target "featured-ros2" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured-base:${STABLE_TAG}"
  }
}

# --- featured derivatives (ascend) ------------------------------------------

target "featured-speit-ai-ascend" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured-base:${STABLE_TAG_ASCEND != "" ? STABLE_TAG_ASCEND : "${STABLE_TAG}-ascend"}"
  }
}

# --- coder derivatives ------------------------------------------------------

target "coder-conda" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-coder-base:${STABLE_TAG}"
  }
}

# --- jupyter derivatives (universal + ascend) --------------------------------

target "jupyter-speit-ai-universal" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-jupyter-base:${STABLE_TAG}"
  }
}

target "jupyter-speit-ai-ascend" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-jupyter-base:${STABLE_TAG_ASCEND != "" ? STABLE_TAG_ASCEND : "${STABLE_TAG}-ascend"}"
  }
}

# --- agent derivatives (universal + ascend) ----------------------------------

target "agent-openclaw-universal" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-agent-base:${STABLE_TAG}"
  }
}

target "agent-openclaw-ascend" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-agent-base:${STABLE_TAG_ASCEND != "" ? STABLE_TAG_ASCEND : "${STABLE_TAG}-ascend"}"
  }
}

target "agent-hermes" {
  contexts = {
    artifacts         = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"      = "docker-image://${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-agent-base:${STABLE_TAG}"
  }
}
