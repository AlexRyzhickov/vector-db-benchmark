# Performance bench harness. Two end-to-end commands:
#   make bench-casper  — clean ./casper/, start it, load HDF5, build f32 then
#                        i8 indices, run goose against each, save results.
#   make bench-qdrant  — same flow for Qdrant (no-quant then int8 scalar).
#
# Targets are split by area under ./make/:
#   dev.mk     — download server binaries, build helper tools, dataset
#   bench.mk   — bench-casper / bench-qdrant / clean and their knobs
#   release.mk — package-linux-x86 (release archive)

HERE := $(CURDIR)

# Compared vector DB versions in this benchmark (override on demand).
CASPER_VERSION ?= v0.2.0
QDRANT_VERSION ?= v1.20.2

.DEFAULT_GOAL := help

include make/dev.mk make/bench.mk make/release.mk

.PHONY: help

help:
	@echo "Targets:"
	@echo "  build-tools-linux-x86 — cross-compile ./import and ./goose for x86_64 Linux (needs Docker + cross)"
	@echo "  download-dataset-deep-image-96-angular.hdf5 — download deep-image-96-angular.hdf5"
	@echo "  download-casper — download/update ./casper/casper binary"
	@echo "  download-qdrant — download/update ./qdrant/qdrant binary"
	@echo "  download-binaries — download/update both server binaries"
	@echo "  package-linux-x86 — build tools + binaries and create the x86_64-unknown-linux-gnu archive"
	@echo "  bench-casper   — full end-to-end bench against Casper (f32 + i8)"
	@echo "  bench-qdrant   — full end-to-end bench against Qdrant (no-quant + int8)"
	@echo "  clean          — remove ./results/ and per-server storage"
	@echo ""
	@echo "Variables (override on the command line):"
	@echo "  HDF5=$(HDF5)"
	@echo "  RESULTS_DIR=$(RESULTS_DIR)"
	@echo "  USERS=$(USERS)"
	@echo "  RUN_TIME_SECONDS=$(RUN_TIME_SECONDS)"
	@echo "  SEARCH_LIMITS=$(SEARCH_LIMITS)"
	@echo "  EF_SEARCH=$(EF_SEARCH)"
	@echo "  QDRANT_USE_OPTIMIZERS_CONFIG=$(QDRANT_USE_OPTIMIZERS_CONFIG)"
	@echo "  QDRANT_DEFAULT_SEGMENT_NUMBER=$(QDRANT_DEFAULT_SEGMENT_NUMBER)"
	@echo "  SERVER_NUMA_NODE=$(SERVER_NUMA_NODE)  (empty = no pinning)"
	@echo "  LOAD_NUMA_NODE=$(LOAD_NUMA_NODE)    (empty = no pinning)"
	@echo "  CASPER_VERSION=$(CASPER_VERSION)"
	@echo "  QDRANT_VERSION=$(QDRANT_VERSION)"
	@echo "  HDF5_URL=$(HDF5_URL)"
	@echo "  DIST_ARCHIVE=$(DIST_ARCHIVE)"
