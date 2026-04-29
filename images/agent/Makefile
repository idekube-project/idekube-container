.PHONY: prepare build buildx publishx build-all publishx-all discover

-include .env
export

BUILDER      := third_party/docker-builder
BUILD_PY     := python3 $(BUILDER)/build.py --project-root=.
BRANCH       ?= agent/openclaw
LINEUP       ?= base
MAX_PARALLEL ?= 2

$(BUILDER)/build.py:
	git submodule update --init --recursive

prepare: $(BUILDER)/build.py

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

discover: prepare
	@$(BUILD_PY) discover
