# IDEKube container meta-repo orchestrator.
#
# All build logic lives in docker-bake.hcl (+ docker-bake.{staging,production}.hcl).
# This Makefile is just a thin wrapper over `docker buildx bake` + the test suite.

SHELL := /bin/bash

# Default target/group when none supplied.
TARGET       ?= base
GROUP        ?= base
LINEUP       ?= base
BRANCH       ?=
MAX_PARALLEL ?= 4

BAKE_FILES_PRODUCTION := -f docker-bake.hcl -f docker-bake.production.hcl
BAKE_FILES_STAGING    := -f docker-bake.hcl -f docker-bake.staging.hcl

.PHONY: help prepare bake bake-staging bake-production push-staging push-production \
        discover discover-staging tag-stable test_deps test test_all test_all_ascend

help:
	@echo "IDEKube container build orchestrator"
	@echo ""
	@echo "Common targets:"
	@echo "  make prepare                          Init submodules"
	@echo "  make bake TARGET=featured-base-base   Local build (single target, host arch, --load)"
	@echo "  make bake-staging GROUP=base          Multi-arch staging build (no push)"
	@echo "  make bake-production GROUP=base       Multi-arch production build (no push)"
	@echo "  make push-staging GROUP=base          Multi-arch staging build + push"
	@echo "  make push-production GROUP=base       Multi-arch production build + push"
	@echo "  make discover GROUP=base              Print bake JSON for a group"
	@echo "  make tag-stable BRANCH=featured/base  Retag pushed image as stable"
	@echo "  make test BRANCH=featured/base        Run test suite against a branch"
	@echo "  make test_all                         Run tests for the entire base lineup"
	@echo "  make test_all_ascend                  Run tests for the entire ascend lineup"

prepare:
	git submodule update --init --recursive

# ---------------------------------------------------------------------------
# Build targets
# ---------------------------------------------------------------------------

# Single-arch local build, loaded into the host docker engine.
# Pass TARGET=<bake-target-name>, e.g. featured-base-base, agent-openclaw.
# Forces single-platform (host arch) because docker's image store can't load manifest lists.
HOST_ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

bake:
	docker buildx bake -f docker-bake.hcl --load --set "*.platform=linux/$(HOST_ARCH)" $(TARGET)

# Multi-arch staging build (no push). Useful before pushing to verify both archs.
bake-staging:
	docker buildx bake $(BAKE_FILES_STAGING) $(GROUP)

# Multi-arch production build (no push).
bake-production:
	docker buildx bake $(BAKE_FILES_PRODUCTION) $(GROUP)

# Multi-arch staging build + push to GHCR.
push-staging:
	docker buildx bake $(BAKE_FILES_STAGING) --push $(GROUP)

# Multi-arch production build + push to GHCR.
push-production:
	docker buildx bake $(BAKE_FILES_PRODUCTION) --push $(GROUP)

# Print bake plan as JSON (great for piping into ci-matrix generation).
discover:
	docker buildx bake --print -f docker-bake.hcl $(GROUP)

discover-staging:
	docker buildx bake --print $(BAKE_FILES_STAGING) $(GROUP)

# After a production push, retag the pushed image with a "stable" alias so
# derived images (in other repos / runtime environments) can FROM <repo>:stable.
# BRANCH must be in the slash-form, e.g. featured/base, agent/openclaw.
tag-stable:
	@if [ -z "$(BRANCH)" ]; then echo "Error: BRANCH=<flavor>/<variant> required"; exit 1; fi
	./scripts/tag-stable.sh $(BRANCH)

# ---------------------------------------------------------------------------
# Tests (migrated from idekube-container-old/Makefile)
# ---------------------------------------------------------------------------

test_deps:
	cd tests && uv sync && uv run playwright install chromium

test:
	cd tests && uv run pytest --branch=$(BRANCH) --lineup=$(LINEUP)

test_all:
	cd tests && uv run pytest --lineup=base -n $(MAX_PARALLEL)

test_all_ascend:
	cd tests && uv run pytest --lineup=ascend -n $(MAX_PARALLEL)
