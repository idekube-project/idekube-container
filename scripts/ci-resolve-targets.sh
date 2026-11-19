#!/usr/bin/env bash
#
# ci-resolve-targets.sh — Validate publish-workflow inputs and decide which
# bake targets one matrix leg builds.
#
# Every value arrives through the environment, never through ${{ }}
# interpolation into shell source, and is checked against a strict pattern
# before anything uses it (bake-action passes targets as CLI arguments, so a
# value like "--set ..." must never get through).
#
# Env:
#   MATRIX_LINEUP    universal | ascend
#   INPUT_TARGETS    optional comma-separated bake targets/groups
#   SKIP_BASE        "true" to pull base images instead of rebuilding them
#   BASE_TAG         optional base image tag used with SKIP_BASE
#   BASE_TAG_ASCEND  optional ascend base image tag used with SKIP_BASE
#   BAKE_OVERRIDE    docker-bake.staging.hcl | docker-bake.production.hcl
#
# Writes "targets=<comma-separated list>" to $GITHUB_OUTPUT.
#
set -euo pipefail

die() { echo "::error::$*" >&2; exit 1; }

TARGETS_RE='^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$'
TAG_RE='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'   # Docker image tag grammar

[[ "${MATRIX_LINEUP:-}" =~ ^(universal|ascend)$ ]] || die "unexpected matrix lineup '${MATRIX_LINEUP:-}'"
[[ "${BAKE_OVERRIDE:-}" =~ ^docker-bake\.(staging|production)\.hcl$ ]] || die "unexpected BAKE_OVERRIDE '${BAKE_OVERRIDE:-}'"
if [[ -n "${INPUT_TARGETS:-}" && ! "$INPUT_TARGETS" =~ $TARGETS_RE ]]; then
    die "targets must be comma-separated bake target/group names (a-z, 0-9, '-'), got '$INPUT_TARGETS'"
fi
for var in BASE_TAG BASE_TAG_ASCEND; do
    value=${!var:-}
    if [[ -n "$value" && ! "$value" =~ $TAG_RE ]]; then
        die "$var is not a valid image tag: '$value'"
    fi
done

skip_base=false
[[ "${SKIP_BASE:-}" == true ]] && skip_base=true

if [[ -n "${INPUT_TARGETS:-}" ]]; then
    targets=$INPUT_TARGETS
elif [[ "$skip_base" == true ]]; then
    # Only the derived targets of this lineup; see docker-bake.skip-base.hcl.
    targets="${MATRIX_LINEUP}-derived"
else
    targets=$MATRIX_LINEUP
fi

if [[ "$skip_base" == true ]]; then
    # skip_base promises not to rebuild or push any base image. Resolve the
    # plan exactly as bake will and refuse if a base target is still in it.
    IFS=, read -ra target_list <<<"$targets"
    planned=$(docker buildx bake --print \
        -f docker-bake.hcl -f "$BAKE_OVERRIDE" -f docker-bake.skip-base.hcl \
        "${target_list[@]}" | jq -r '.target | keys[]')
    base_targets=$(grep -E '(^|-)base(-|$)' <<<"$planned" | paste -sd, - || true)
    if [[ -n "$base_targets" ]]; then
        die "skip_base is enabled but '$targets' still builds base images ($base_targets). Request derived targets only (e.g. ${MATRIX_LINEUP}-derived) or turn skip_base off."
    fi
fi

echo "Resolved bake targets: $targets"
echo "targets=$targets" >> "${GITHUB_OUTPUT:-/dev/stdout}"
