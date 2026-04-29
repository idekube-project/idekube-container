.PHONY: prepare build buildx publishx build-all publishx-all tag-stable discover

-include .env
export

BUILDER      := third_party/docker-builder
BUILD_PY     := python3 $(BUILDER)/build.py --project-root=.
BRANCH       ?= jupyter/base
LINEUP       ?= base
MAX_PARALLEL ?= 2

# --- Submodule initialization ---
$(BUILDER)/build.py:
	git submodule update --init --recursive

# --- Prepare symlinks ---
prepare: $(BUILDER)/build.py
	@# Common rootfs from artifacts repo
	@mkdir -p artifacts/docker
	@ln -sfn ../../third_party/artifacts/rootfs artifacts/docker/rootfs
	@# Shared install scripts
	@ln -sfn ../third_party/artifacts/install-scripts shared-install-scripts
	@# Healthcheck Go source
	@mkdir -p tools
	@ln -sfn ../third_party/healthcheck tools/idekube-healthcheck
	@# Frontend
	@cd third_party/frontend && npm ci && npm run build
	@mkdir -p frontend
	@ln -sfn ../third_party/frontend/dist frontend/dist

# --- Docker targets ---
build: prepare
	@$(BUILD_PY) build $(BRANCH) --lineup=$(LINEUP)

buildx: prepare
	@$(BUILD_PY) buildx $(BRANCH) --lineup=$(LINEUP)

publishx: prepare
	@$(BUILD_PY) publishx $(BRANCH) --lineup=$(LINEUP)

build-all: prepare
	@$(BUILD_PY) build-all --lineup=$(LINEUP) --parallel=$(MAX_PARALLEL)

publishx-all: prepare
	@$(BUILD_PY) publishx-all --lineup=$(LINEUP) --parallel=$(MAX_PARALLEL)

tag-stable:
	@$(BUILD_PY) tag-stable $(BRANCH) --lineup=$(LINEUP)

# --- Info ---
discover: prepare
	@$(BUILD_PY) discover

list: prepare
	@$(BUILD_PY) list --lineup=$(LINEUP)

ci-matrix: prepare
	@$(BUILD_PY) ci-matrix --lineup=$(LINEUP) --pretty

clean:
	rm -f artifacts/docker/rootfs shared-install-scripts tools/idekube-healthcheck frontend/dist
