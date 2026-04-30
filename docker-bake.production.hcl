# Production override file. Layered after docker-bake.hcl:
#   docker buildx bake -f docker-bake.hcl -f docker-bake.production.hcl <group> --push
#
# Triggered by tag pushes (v*) in CI. The "stable" tag aliases are not added
# here; they're applied as a post-build step via scripts/tag-stable.sh which
# uses `docker buildx imagetools create` against already-pushed manifests.

# Enable GitHub Actions cache for production runs to speed up rebuilds.
target "_common" {
  cache-from = ["type=gha"]
  cache-to   = ["type=gha,mode=max"]
}
