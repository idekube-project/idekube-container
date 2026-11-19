# Production override file. Layered after docker-bake.hcl for local builds:
#   docker buildx bake -f docker-bake.hcl -f docker-bake.production.hcl <group> --push
#
# CI never builds production images. publish-staging builds and tests a
# candidate ("-staging" tags), and publish-production promotes those exact
# digests to the release tags (scripts/ci/bakeplan.py promote). A local
# `make push-production` bypasses that gate: use it only to recover from a
# broken pipeline.
#
# Release tags come from docker-bake.hcl alone (STAGING_POSTFIX empty), so
# this file intentionally overrides nothing.
