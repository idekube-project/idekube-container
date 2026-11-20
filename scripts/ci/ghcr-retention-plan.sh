#!/usr/bin/env bash
# Inputs for the GHCR retention run (.github/workflows/ghcr-cleanup.yml).
#
# Prints, as key=value lines (appended to $GITHUB_OUTPUT when set):
#   packages    the GHCR packages docker-bake.hcl publishes to, comma-separated
#   exclude     regex of staging tags to keep regardless of age:
#                 - the edge pointers docker-bake.staging.hcl currently tags
#                 - candidates of prereleases newer than the latest release,
#                   which publish-production still needs to promote
#   older_than  validated minimum age (default "30 days", at least 7 days)
#
# Env: REPO (owner/name), GH_TOKEN, OLDER_THAN (optional).
set -euo pipefail

cd "$(dirname "$0")/../.."

: "${REPO:?REPO is not set (owner/name)}"
owner=${REPO%%/*}

# --- packages: whatever bake tags, under ghcr.io/<owner>/ ---------------------
packages=$(docker buildx bake -f docker-bake.hcl --print all 2>/dev/null \
  | jq -r --arg prefix "ghcr.io/$owner/" '
      [.target[] | .tags[]? | select(startswith($prefix))
       | ltrimstr($prefix) | split(":")[0]] | unique | join(",")')
if [[ ! "$packages" =~ ^[a-z0-9._-]+(,[a-z0-9._-]+)*$ ]]; then
  echo "::error::no GHCR packages found in docker-bake.hcl (got '${packages}')" >&2
  exit 1
fi

# --- minimum age ----------------------------------------------------------
older_than=${OLDER_THAN:-30 days}
if [[ "$older_than" =~ ^([0-9]+)\ (days?|weeks?|months?|years?)$ ]]; then
  n=$((10#${BASH_REMATCH[1]}))
  unit=${BASH_REMATCH[2]}
  # Younger than a week could catch a running build's by-digest pushes
  # before they are merged into a tagged index.
  if (( n < 1 )) || { [[ "$unit" == day* ]] && (( n < 7 )); }; then
    echo "::error::older_than must be at least 7 days (got '$older_than')" >&2
    exit 1
  fi
  older_than="$n $unit"
else
  echo "::error::older_than must look like '30 days', '6 weeks', '3 months' (got '$older_than')" >&2
  exit 1
fi

# --- staging tags to keep -------------------------------------------------
# The edge pointers bake currently produces (a removed variant's stale
# pointer is not kept).
edge=$(VERSION=edge docker buildx bake -f docker-bake.hcl -f docker-bake.staging.hcl --print all 2>/dev/null \
  | jq -r --arg prefix "ghcr.io/$owner/" '
      [.target[] | .tags[]? | select(startswith($prefix)) | split(":")[1]]
      | unique | map(gsub("\\."; "\\.")) | join("|")')
if [[ ! "$edge" =~ edge-staging ]]; then
  echo "::error::no edge-staging tags found in the staging bake plan (got '${edge}')" >&2
  exit 1
fi
exclude="^(${edge})\$"

latest=$(gh api "repos/$REPO/releases/latest" --jq .tag_name 2>/dev/null || true)
prereleases=$(gh release list --repo "$REPO" --limit 100 \
  --json tagName,isPrerelease,isDraft \
  --jq '.[] | select(.isPrerelease and (.isDraft | not)) | .tagName')

while IFS= read -r tag; do
  [[ -n "$tag" ]] || continue
  if [[ ! "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "::error::unexpected release tag '$tag'" >&2
    exit 1
  fi
  if [[ -n "$latest" ]]; then
    newest=$(printf '%s\n%s\n' "$latest" "$tag" | sort -V | tail -n1)
    [[ "$tag" != "$latest" && "$newest" == "$tag" ]] || continue
  fi
  exclude+="|(^|-)${tag//./\\.}(-ascend)?-staging\$"
  echo "keeping the candidate of prerelease $tag" >&2
done <<< "$prereleases"

# ghcr-cleanup-action rejects longer patterns.
if (( ${#exclude} > 1000 )); then
  echo "::error::exclude pattern is ${#exclude} characters, the cleanup action accepts 1000" >&2
  exit 1
fi

out=${GITHUB_OUTPUT:-/dev/stdout}
{
  echo "packages=$packages"
  echo "exclude=$exclude"
  echo "older_than=$older_than"
} >> "$out"
