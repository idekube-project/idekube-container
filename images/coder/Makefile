.PHONY: prepare build buildx publishx discover

-include .env
export

BUILDER      := third_party/docker-builder
BUILD_PY     := python3 $(BUILDER)/build.py --project-root=.
BRANCH       ?= coder/conda
LINEUP       ?= base

$(BUILDER)/build.py:
	git submodule update --init --recursive

prepare: $(BUILDER)/build.py

build: prepare
	@$(BUILD_PY) build $(BRANCH) --lineup=$(LINEUP)

buildx: prepare
	@$(BUILD_PY) buildx $(BRANCH) --lineup=$(LINEUP)

publishx: prepare
	@$(BUILD_PY) publishx $(BRANCH) --lineup=$(LINEUP)

discover: prepare
	@$(BUILD_PY) discover
