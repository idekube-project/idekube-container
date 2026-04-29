.PHONY: prepare build buildx publishx build-all publishx-all discover \
       prepare_qemu_files build_qemu_tools build_qemu_root build_qemu publish_qemu

-include .env
export

BUILDER      := third_party/docker-builder
BUILD_PY     := python3 $(BUILDER)/build.py --project-root=.
BRANCH       ?= featured/speit
LINEUP       ?= base
MAX_PARALLEL ?= 2

$(BUILDER)/build.py:
	git submodule update --init --recursive

prepare: $(BUILDER)/build.py
	@ln -sfn ../third_party/artifacts/install-scripts shared-install-scripts
	@# QEMU builder: scripts, manifests, artifacts, tools
	@mkdir -p scripts
	@ln -sfn ../third_party/qemu-builder/scripts/shell scripts/shell
	@mkdir -p manifests/qemu/featured
	@ln -sfn ../../../third_party/qemu-builder/manifests/qemu/Dockerfile manifests/qemu/Dockerfile
	@ln -sfn ../../../third_party/qemu-builder/manifests/qemu/Dockerfile.engine manifests/qemu/Dockerfile.engine
	@ln -sfn ../../../qemu/kathara manifests/qemu/featured/kathara
	@mkdir -p artifacts/qemu
	@ln -sfn ../../third_party/qemu-builder/artifacts/configs artifacts/qemu/configs
	@ln -sfn ../../third_party/qemu-builder/artifacts/rootfs artifacts/qemu/rootfs
	@ln -sfn ../../third_party/qemu-builder/artifacts/startup-scripts artifacts/qemu/startup-scripts
	@ln -sfn ../../third_party/qemu-builder/artifacts/featured artifacts/qemu/featured
	@mkdir -p tools/utility
	@ln -sfn ../../third_party/qemu-builder/tools/utility/cloud-localds tools/utility/cloud-localds

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

# --- QEMU targets ---
prepare_qemu_files: prepare
	@$(BUILD_PY) qemu-prepare

build_qemu_tools: prepare_qemu_files
	@$(BUILD_PY) qemu-build-tools

build_qemu_root: build_qemu_tools
	@$(BUILD_PY) qemu-build-root $(BRANCH)

build_qemu: build_qemu_root
	@$(BUILD_PY) qemu-build $(BRANCH)

publish_qemu:
	@$(BUILD_PY) qemu-publish $(BRANCH)

# --- Info ---
discover: prepare
	@$(BUILD_PY) discover

list: prepare
	@$(BUILD_PY) list --lineup=$(LINEUP)

ci-matrix: prepare
	@$(BUILD_PY) ci-matrix --lineup=$(LINEUP) --pretty

clean:
	rm -f shared-install-scripts
