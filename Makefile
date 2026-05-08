# IDEKube container meta-repo orchestrator.
#
# All build logic lives in docker-bake.hcl (+ docker-bake.{staging,production}.hcl).
# This Makefile is just a thin wrapper over `docker buildx bake` + the test suite.

SHELL := /bin/bash

# Default target/group when none supplied.
TARGET       ?= universal
GROUP        ?= universal
LINEUP       ?= universal
BRANCH       ?=
MAX_PARALLEL ?= 4
BUILDX_BUILDER ?= idekube-builder
BUILDX_DRIVER  ?= docker-container

BAKE_FILES_PRODUCTION := -f docker-bake.hcl -f docker-bake.production.hcl
BAKE_FILES_STAGING    := -f docker-bake.hcl -f docker-bake.staging.hcl

.PHONY: help prepare buildx-preflight bake bake-staging bake-production push-staging \
        push-production discover discover-staging tag-stable test_deps test test_all \
        test_all_ascend qemu-files qemu-images qemu-tools qemu-cloud-localds \
        qemu-prepare qemu-engine qemu-root qemu-build qemu-image qemu-wsl

help:
	@echo "IDEKube container build orchestrator"
	@echo ""
	@echo "Common targets:"
	@echo "  make prepare                          Init submodules"
	@echo "  make buildx-preflight                 Create/use the buildx docker-container builder"
	@echo "  make bake TARGET=featured-base-universal  Local build (single target, host arch, --load)"
	@echo "  make bake-staging GROUP=universal         Multi-arch staging build (no push)"
	@echo "  make bake-production GROUP=universal      Multi-arch production build (no push)"
	@echo "  make push-staging GROUP=universal         Multi-arch staging build + push"
	@echo "  make push-production GROUP=universal      Multi-arch production build + push"
	@echo "  make discover GROUP=universal             Print bake JSON for a group"
	@echo "  make tag-stable BRANCH=featured/base  Retag pushed image as stable"
	@echo "  make test BRANCH=featured/base        Run test suite against a branch"
	@echo "  make test_all                         Run tests for the entire universal lineup"
	@echo "  make test_all_ascend                  Run tests for the entire ascend lineup"
	@echo "  make qemu-image BRANCH=featured/base  Build QEMU root disk + runtime image"

prepare:
	git submodule update --init --recursive

# Ensure multi-platform builds use a buildx builder backed by the docker-container
# driver. Docker's default "docker" driver cannot build multi-platform images.
buildx-preflight:
	@set -euo pipefail; \
	if [ -z "$(BUILDX_BUILDER)" ]; then \
		echo "Error: BUILDX_BUILDER cannot be empty."; \
		exit 1; \
	fi; \
	if docker buildx inspect $(BUILDX_BUILDER) >/dev/null 2>&1; then \
		driver=$$(docker buildx inspect $(BUILDX_BUILDER) | awk '/^Driver:/ { print $$2 }'); \
		if [ "$$driver" != "$(BUILDX_DRIVER)" ]; then \
			if [ "$(BUILDX_BUILDER)" = "default" ]; then \
				echo "Error: docker's default buildx builder uses driver '$$driver', expected '$(BUILDX_DRIVER)'."; \
				echo "Set BUILDX_BUILDER to a non-default name so make can manage it idempotently."; \
				exit 1; \
			fi; \
			echo "Recreating buildx builder '$(BUILDX_BUILDER)' ($$driver -> $(BUILDX_DRIVER))"; \
			docker buildx rm $(BUILDX_BUILDER) >/dev/null; \
			docker buildx create --name $(BUILDX_BUILDER) --driver $(BUILDX_DRIVER) >/dev/null; \
		fi; \
	else \
		echo "Creating buildx builder '$(BUILDX_BUILDER)' ($(BUILDX_DRIVER))"; \
		docker buildx create --name $(BUILDX_BUILDER) --driver $(BUILDX_DRIVER) >/dev/null; \
	fi; \
	docker buildx use $(BUILDX_BUILDER); \
	docker buildx inspect --bootstrap >/dev/null; \
	echo "Buildx builder '$(BUILDX_BUILDER)' is ready ($(BUILDX_DRIVER))"

# ---------------------------------------------------------------------------
# Build targets
# ---------------------------------------------------------------------------

# Single-arch local build, loaded into the host docker engine.
# Pass TARGET=<bake-target-name>, e.g. featured-base-universal, agent-openclaw.
# Forces single-platform (host arch) because docker's image store can't load manifest lists.
HOST_ARCH := $(shell uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')

bake: buildx-preflight
	docker buildx bake -f docker-bake.hcl --load --set "*.platform=linux/$(HOST_ARCH)" $(TARGET)

# Multi-arch staging build (no push). Useful before pushing to verify both archs.
bake-staging: buildx-preflight
	docker buildx bake $(BAKE_FILES_STAGING) $(GROUP)

# Multi-arch production build (no push).
bake-production: buildx-preflight
	docker buildx bake $(BAKE_FILES_PRODUCTION) $(GROUP)

# Multi-arch staging build + push to GHCR.
push-staging: buildx-preflight
	docker buildx bake $(BAKE_FILES_STAGING) --push $(GROUP)

# Multi-arch production build + push to GHCR.
push-production: buildx-preflight
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
	LINEUP="$(LINEUP)" VERSION="$(VERSION)" ./scripts/tag-stable.sh "$(BRANCH)"

# ---------------------------------------------------------------------------
# QEMU VM image pipeline
# ---------------------------------------------------------------------------

qemu-files:
	cd qemu-builder && bash scripts/shell/prepare_qemu_files.sh

qemu-images:
	cd qemu-builder && bash scripts/shell/prepare_qemu_images.sh

qemu-tools:
	cd qemu-builder && bash scripts/shell/prepare_qemu_tools.sh

qemu-cloud-localds:
	cd qemu-builder && docker build -t cloud-localds:latest tools/utility/cloud-localds

qemu-prepare: qemu-files qemu-images qemu-tools qemu-cloud-localds

qemu-engine: qemu-files
	cd qemu-builder && docker build -t idekube-qemu-engine:latest -f manifests/qemu/Dockerfile.engine .

qemu-root: qemu-images qemu-tools qemu-cloud-localds qemu-engine
	@if [ -z "$(BRANCH)" ]; then echo "Error: BRANCH=<flavor>/<variant> required"; exit 1; fi
	cd qemu-builder && BRANCH=$(BRANCH) bash scripts/shell/build_qemu_root.sh

qemu-build:
	@if [ -z "$(BRANCH)" ]; then echo "Error: BRANCH=<flavor>/<variant> required"; exit 1; fi
	cd qemu-builder && BRANCH=$(BRANCH) bash scripts/shell/build_qemu.sh

qemu-image: qemu-root qemu-build

qemu-wsl:
	@if [ -z "$(BRANCH)" ]; then echo "Error: BRANCH=<flavor>/<variant> required"; exit 1; fi
	cd qemu-builder && BRANCH=$(BRANCH) bash scripts/shell/build_wsl.sh

# ---------------------------------------------------------------------------
# Tests (migrated from idekube-container-old/Makefile)
# ---------------------------------------------------------------------------

test_deps:
	cd tests && uv sync && uv run playwright install chromium

test:
	cd tests && uv run pytest --branch=$(BRANCH) --lineup=$(LINEUP)

test_all:
	cd tests && uv run pytest --lineup=universal -n $(MAX_PARALLEL)

test_all_ascend:
	cd tests && uv run pytest --lineup=ascend -n $(MAX_PARALLEL)
