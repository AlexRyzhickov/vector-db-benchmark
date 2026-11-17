# Dev: server binaries, helper tools and the dataset.
#
# Binaries are not stored in git: server binaries are downloaded from GitHub
# releases and helper tools are built with cargo on first use. Re-run
# `make download-binaries` / `make build-tools-linux-x86` to refresh them.

TOOLS_DIR ?= $(HERE)/.tools

# The one platform the bench is built for, whatever the host: server binaries
# are downloaded for it and import/goose are cross-compiled for it with `cross`
# (Cross.toml). `cross` needs Docker running and, once:
#   cargo install cross --git https://github.com/cross-rs/cross
# and on an Apple Silicon host also the Linux toolchain cross mounts into its
# (x86_64) image:
#   rustup toolchain add 1.100.0-x86_64-unknown-linux-gnu --profile minimal --force-non-host
# (the version is the one in rust-toolchain.toml)
LINUX_X86_TARGET := x86_64-unknown-linux-gnu

CASPER_TARBALL_URL ?= https://github.com/casper-vdb/casper/releases/download/$(CASPER_VERSION)/casper-$(LINUX_X86_TARGET).tar.gz
QDRANT_TARBALL_URL ?= https://github.com/qdrant/qdrant/releases/download/$(QDRANT_VERSION)/qdrant-$(LINUX_X86_TARGET).tar.gz
HDF5_URL ?= http://ann-benchmarks.com/deep-image-96-angular.hdf5

CASPER_BIN := $(HERE)/casper/casper
QDRANT_BIN := $(HERE)/qdrant/qdrant
IMPORT_BIN := $(HERE)/import/import
GOOSE_BIN := $(HERE)/goose/goose

.PHONY: build-tools-linux-x86 download-dataset-deep-image-96-angular.hdf5 download-casper download-qdrant download-binaries

build-tools-linux-x86:
	$(MAKE) -C $(HERE)/import build-linux-x86
	$(MAKE) -C $(HERE)/goose build-linux-x86

download-dataset-deep-image-96-angular.hdf5:
	@echo "Downloading dataset from $(HDF5_URL)"
	@wget "$(HDF5_URL)"

download-casper:
	@mkdir -p $(TOOLS_DIR) $(HERE)/casper
	@echo "Downloading Casper from $(CASPER_TARBALL_URL)"
	@curl -fL --retry 3 --retry-delay 2 -o $(TOOLS_DIR)/casper.tar.gz "$(CASPER_TARBALL_URL)"
	@tar -xzf $(TOOLS_DIR)/casper.tar.gz -C $(TOOLS_DIR)
	@install -m 0755 $(TOOLS_DIR)/casper $(HERE)/casper/casper
	@rm -f $(TOOLS_DIR)/casper.tar.gz $(TOOLS_DIR)/casper
	@echo "Installed $(HERE)/casper/casper"

download-qdrant:
	@mkdir -p $(TOOLS_DIR) $(HERE)/qdrant
	@echo "Downloading Qdrant from $(QDRANT_TARBALL_URL)"
	@curl -fL --retry 3 --retry-delay 2 -o $(TOOLS_DIR)/qdrant.tar.gz "$(QDRANT_TARBALL_URL)"
	@tar -xzf $(TOOLS_DIR)/qdrant.tar.gz -C $(TOOLS_DIR)
	@install -m 0755 $(TOOLS_DIR)/qdrant $(HERE)/qdrant/qdrant
	@rm -f $(TOOLS_DIR)/qdrant.tar.gz $(TOOLS_DIR)/qdrant
	@echo "Installed $(HERE)/qdrant/qdrant"

download-binaries: download-casper download-qdrant

# Fetch/build a binary only when it is missing.
$(CASPER_BIN):
	@$(MAKE) --no-print-directory download-casper

$(QDRANT_BIN):
	@$(MAKE) --no-print-directory download-qdrant

$(IMPORT_BIN):
	$(MAKE) -C $(HERE)/import build-linux-x86

$(GOOSE_BIN):
	$(MAKE) -C $(HERE)/goose build-linux-x86
