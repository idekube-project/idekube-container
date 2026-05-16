# IDEKube container build orchestration via docker buildx bake.
#
# Source-of-truth for every image in the project. Replaces the per-submodule
# Makefiles + the old docker-builder Python orchestrator. Image submodules
# under images/ are stand-alone source trees; bake supplies shared assets
# (artifacts/, healthcheck/, frontend/) via named build contexts so that
# each Dockerfile only references paths inside its own repo.
#
# Usage:
#   docker buildx bake universal                 # production build, universal lineup, no push
#   docker buildx bake -f docker-bake.hcl -f docker-bake.staging.hcl universal --push
#   docker buildx bake --print universal         # discover (prints JSON)
#
# Variable overrides go through env (variable blocks) or --set (target attrs).

# ---------------------------------------------------------------------------
# Top-level variables (env-overridable)
# ---------------------------------------------------------------------------

variable "REGISTRY"        { default = "ghcr.io" }
variable "AUTHOR"          { default = "idekube-project" }
variable "NAME_PREFIX"     { default = "idekube-container" }
variable "VERSION"         { default = "latest" }   # CI sets from git tag or short sha
variable "STAGING_POSTFIX" { default = "" }          # "-staging" via docker-bake.staging.hcl

# Build args replacing the old .dockerargs.base file.
variable "TZ"                     { default = "Asia/Shanghai" }
variable "APT_MIRROR"             { default = "mirror.sjtu.edu.cn" }
variable "USE_APT_MIRROR"         { default = "false" }
variable "PIP_MIRROR_URL"         { default = "https://mirror.sjtu.edu.cn/pypi/web/simple" }
variable "USE_PIP_MIRROR"         { default = "false" }
variable "TINI_VERSION"           { default = "0.19.0" }
variable "WEBSOCAT_VERSION"       { default = "1.13.0" }
variable "TTYD_VERSION"           { default = "1.7.7" }
variable "MINICONDA_VERSION"      { default = "py313_25.11.1-1" }
variable "CODER_VERSION"          { default = "4.92.2" }
variable "VIRTUALGL_VERSION"      { default = "3.1" }
variable "TURBOVNC_VERSION"       { default = "3.1" }
variable "NODE_MAJOR"             { default = "22" }
variable "OPENCODE_VERSION"       { default = "1.4.3" }
variable "OPENCLAW_VERSION"       { default = "2026.4.26" }
variable "CLAUDE_CODE_VERSION"    { default = "2.1.104" }
variable "HERMES_VERSION"         { default = "main" }
variable "DIGITAL_VERSION"        { default = "0.31" }
variable "IVERILOG_VERSION"       { default = "v12_0" }
variable "DOCKER_CHANNEL"         { default = "stable" }
variable "DOCKER_VERSION"         { default = "27.2.1" }
variable "DOCKER_COMPOSE_VERSION" { default = "v2.29.2" }
variable "BUILDX_VERSION"         { default = "v0.16.2" }
variable "DEBUG"                  { default = "false" }
variable "ROS_DISTRO"             { default = "jazzy" }
variable "QEMU_VERSION"           { default = "10.2.0" }

# Lineup definitions (consumed by matrix-expanded dual-lineup targets).
# Each entry carries the per-lineup overrides: BASE_IMAGE, TAG_POSTFIX, platforms.
variable "LINEUPS" {
  default = [
    { lineup = "universal", base = "ubuntu:24.04",                                  postfix = "",         platforms = ["linux/amd64", "linux/arm64"] },
    { lineup = "ascend",    base = "ascendai/cann:8.3.rc2-910b-ubuntu22.04-py3.11", postfix = "-ascend",  platforms = ["linux/arm64"] }
  ]
}

# ---------------------------------------------------------------------------
# Common scaffolding
# ---------------------------------------------------------------------------

# Shared named contexts and build args. Concrete targets inherit this and
# override context/dockerfile/tags/platforms (and add per-target contexts
# such as base-image = target:foo for the dependency chain).
target "_common" {
  contexts = {
    artifacts        = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
  }
  args = {
    REGISTRY               = REGISTRY
    AUTHOR                 = AUTHOR
    GIT_TAG                = VERSION
    TZ                     = TZ
    APT_MIRROR             = APT_MIRROR
    USE_APT_MIRROR         = USE_APT_MIRROR
    PIP_MIRROR_URL         = PIP_MIRROR_URL
    USE_PIP_MIRROR         = USE_PIP_MIRROR
    TINI_VERSION           = TINI_VERSION
    WEBSOCAT_VERSION       = WEBSOCAT_VERSION
    TTYD_VERSION           = TTYD_VERSION
    MINICONDA_VERSION      = MINICONDA_VERSION
    CODER_VERSION          = CODER_VERSION
    VIRTUALGL_VERSION      = VIRTUALGL_VERSION
    TURBOVNC_VERSION       = TURBOVNC_VERSION
    NODE_MAJOR             = NODE_MAJOR
    OPENCODE_VERSION       = OPENCODE_VERSION
    OPENCLAW_VERSION       = OPENCLAW_VERSION
    CLAUDE_CODE_VERSION    = CLAUDE_CODE_VERSION
    HERMES_VERSION         = HERMES_VERSION
    DIGITAL_VERSION        = DIGITAL_VERSION
    IVERILOG_VERSION       = IVERILOG_VERSION
    DOCKER_CHANNEL         = DOCKER_CHANNEL
    DOCKER_VERSION         = DOCKER_VERSION
    DOCKER_COMPOSE_VERSION = DOCKER_COMPOSE_VERSION
    BUILDX_VERSION         = BUILDX_VERSION
    DEBUG                  = DEBUG
    ROS_DISTRO             = ROS_DISTRO
    QEMU_VERSION           = QEMU_VERSION
  }
  platforms = ["linux/amd64", "linux/arm64"]
}

# ---------------------------------------------------------------------------
# featured/* (dual-lineup universal/ascend, single-lineup derivatives)
# ---------------------------------------------------------------------------

target "featured-base" {
  inherits   = ["_common"]
  matrix     = { item = LINEUPS }
  name       = "featured-base-${item.lineup}"
  context    = "images/featured-base"
  dockerfile = "docker/base/Dockerfile"
  args = {
    BASE_IMAGE  = item.base
    NAME        = "${NAME_PREFIX}-featured-base"
    TAG_POSTFIX = item.postfix
  }
  platforms = item.platforms
  tags      = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured-base:${VERSION}${item.postfix}${STAGING_POSTFIX}"]
}

target "featured-speit" {
  inherits   = ["_common"]
  context    = "images/featured"
  dockerfile = "docker/speit/Dockerfile"
  contexts   = {
    artifacts        = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"     = "target:featured-base-universal"
  }
  args = {
    NAME        = "${NAME_PREFIX}-featured"
    TAG_POSTFIX = ""
  }
  tags = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured:speit-${VERSION}${STAGING_POSTFIX}"]
}

target "featured-speit-ai" {
  inherits   = ["_common"]
  matrix     = { item = LINEUPS }
  name       = "featured-speit-ai-${item.lineup}"
  context    = "images/featured"
  dockerfile = "docker/speit-ai/Dockerfile"
  contexts   = {
    artifacts        = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"     = "target:featured-base-${item.lineup}"
  }
  args = {
    NAME        = "${NAME_PREFIX}-featured"
    TAG_POSTFIX = item.postfix
  }
  platforms = item.platforms
  tags      = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured:speit-ai-${VERSION}${item.postfix}${STAGING_POSTFIX}"]
}

target "featured-dind" {
  inherits   = ["_common"]
  context    = "images/featured"
  dockerfile = "docker/dind/Dockerfile"
  contexts   = {
    artifacts        = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"     = "target:featured-base-universal"
  }
  args = { NAME = "${NAME_PREFIX}-featured", TAG_POSTFIX = "" }
  tags = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured:dind-${VERSION}${STAGING_POSTFIX}"]
}

target "featured-kathara" {
  inherits   = ["_common"]
  context    = "images/featured"
  dockerfile = "docker/kathara/Dockerfile"
  contexts   = {
    artifacts        = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"     = "target:featured-dind"
  }
  args = { NAME = "${NAME_PREFIX}-featured", TAG_POSTFIX = "" }
  tags = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured:kathara-${VERSION}${STAGING_POSTFIX}"]
}

target "featured-ros2" {
  inherits   = ["_common"]
  context    = "images/featured"
  dockerfile = "docker/ros2/Dockerfile"
  contexts   = {
    artifacts        = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"     = "target:featured-base-universal"
  }
  args = { NAME = "${NAME_PREFIX}-featured", TAG_POSTFIX = "" }
  tags = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-featured:ros2-${VERSION}${STAGING_POSTFIX}"]
}

# ---------------------------------------------------------------------------
# coder/*
# ---------------------------------------------------------------------------

target "coder-base" {
  inherits   = ["_common"]
  context    = "images/coder-base"
  dockerfile = "docker/base/Dockerfile"
  args = {
    BASE_IMAGE  = "ubuntu:24.04"
    NAME        = "${NAME_PREFIX}-coder-base"
    TAG_POSTFIX = ""
  }
  tags = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-coder-base:${VERSION}${STAGING_POSTFIX}"]
}

target "coder-conda" {
  inherits   = ["_common"]
  context    = "images/coder"
  dockerfile = "docker/conda/Dockerfile"
  contexts   = {
    artifacts        = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"     = "target:coder-base"
  }
  args = { NAME = "${NAME_PREFIX}-coder", TAG_POSTFIX = "" }
  tags = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-coder:conda-${VERSION}${STAGING_POSTFIX}"]
}

# ---------------------------------------------------------------------------
# jupyter/* (dual-lineup universal/ascend, derivatives split universal/ascend)
# ---------------------------------------------------------------------------

target "jupyter-base" {
  inherits   = ["_common"]
  matrix     = { item = LINEUPS }
  name       = "jupyter-base-${item.lineup}"
  context    = "images/jupyter-base"
  dockerfile = "docker/base/Dockerfile"
  args = {
    BASE_IMAGE  = item.base
    NAME        = "${NAME_PREFIX}-jupyter-base"
    TAG_POSTFIX = item.postfix
  }
  platforms = item.platforms
  tags      = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-jupyter-base:${VERSION}${item.postfix}${STAGING_POSTFIX}"]
}

target "jupyter-speit-ai" {
  inherits   = ["_common"]
  matrix     = { item = LINEUPS }
  name       = "jupyter-speit-ai-${item.lineup}"
  context    = "images/jupyter"
  dockerfile = "docker/speit-ai/Dockerfile"
  contexts   = {
    artifacts        = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"     = "target:jupyter-base-${item.lineup}"
  }
  args = {
    NAME        = "${NAME_PREFIX}-jupyter"
    TAG_POSTFIX = item.postfix
  }
  platforms = item.platforms
  tags      = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-jupyter:speit-ai-${VERSION}${item.postfix}${STAGING_POSTFIX}"]
}

# ---------------------------------------------------------------------------
# agent/*
# ---------------------------------------------------------------------------

target "agent-base" {
  inherits   = ["_common"]
  context    = "images/agent-base"
  dockerfile = "docker/base/Dockerfile"
  args = {
    BASE_IMAGE  = "ubuntu:24.04"
    NAME        = "${NAME_PREFIX}-agent-base"
    TAG_POSTFIX = ""
  }
  tags = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-agent-base:${VERSION}${STAGING_POSTFIX}"]
}

target "agent-openclaw" {
  inherits   = ["_common"]
  context    = "images/agent"
  dockerfile = "docker/openclaw/Dockerfile"
  contexts   = {
    artifacts        = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"     = "target:agent-base"
  }
  args = { NAME = "${NAME_PREFIX}-agent", TAG_POSTFIX = "" }
  tags = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-agent:openclaw-${VERSION}${STAGING_POSTFIX}"]
}

target "agent-hermes" {
  inherits   = ["_common"]
  context    = "images/agent"
  dockerfile = "docker/hermes/Dockerfile"
  contexts   = {
    artifacts        = "artifacts"
    "healthcheck-src" = "healthcheck"
    "frontend-src"    = "frontend"
    "base-image"     = "target:agent-base"
  }
  args = { NAME = "${NAME_PREFIX}-agent", TAG_POSTFIX = "" }
  tags = ["${REGISTRY}/${AUTHOR}/${NAME_PREFIX}-agent:hermes-${VERSION}${STAGING_POSTFIX}"]
}

# ---------------------------------------------------------------------------
# Groups
# ---------------------------------------------------------------------------

# Default group when invoked as `docker buildx bake`. Builds the universal lineup.
group "default" {
  targets = ["universal"]
}

# Universal lineup: ubuntu-based, multi-arch (amd64+arm64).
group "universal" {
  targets = [
    "featured-base-universal",
    "featured-speit",
    "featured-speit-ai-universal",
    "featured-dind",
    "featured-kathara",
    "featured-ros2",
    "coder-base",
    "coder-conda",
    "jupyter-base-universal",
    "jupyter-speit-ai-universal",
    "agent-base",
    "agent-openclaw",
    "agent-hermes",
  ]
}

# Ascend lineup: CANN-based, arm64-only.
group "ascend" {
  targets = [
    "featured-base-ascend",
    "featured-speit-ai-ascend",
    "jupyter-base-ascend",
    "jupyter-speit-ai-ascend",
  ]
}

# Per-flavor convenience groups (handy for local dev: `bake featured`).
group "featured-base-all" { targets = ["featured-base-universal", "featured-base-ascend"] }
group "featured" {
  targets = [
    "featured-base-universal",
    "featured-speit",
    "featured-speit-ai-universal",
    "featured-dind",
    "featured-kathara",
    "featured-ros2",
  ]
}
group "coder"   { targets = ["coder-base", "coder-conda"] }
group "jupyter" {
  targets = [
    "jupyter-base-universal",
    "jupyter-base-ascend",
    "jupyter-speit-ai-universal",
    "jupyter-speit-ai-ascend",
  ]
}
group "agent"   { targets = ["agent-base", "agent-openclaw", "agent-hermes"] }

# Build everything (used in CI for combined-mode runs).
group "all" {
  targets = ["universal", "ascend"]
}
