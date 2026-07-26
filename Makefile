# Performance bench harness. Two end-to-end commands:
#   make bench-casper  — clean ./casper/, start it, load HDF5, build f32 then
#                        i8 indices, run goose against each, save results.
#   make bench-qdrant  — same flow for Qdrant (no-quant then int8 scalar).
#
# All artifacts (server logs, goose results) end up under ./results/.
# Server storage directories are wiped before each bench so runs are
# independent.

HERE := $(CURDIR)
HDF5 ?= $(HERE)/deep-image-96-angular.hdf5
RESULTS_DIR ?= $(HERE)/results
TOOLS_DIR ?= $(HERE)/.tools
DIST_ARCHIVE ?= vector-db-benchmark-unknown-linux-gnu.tar.gz

# Casper dev token from README. Override only if you've rotated tokens.
API_TOKEN ?= eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3OTMyOTAzNTMsImZyZWUiOnRydWV9.GxqiVw5kPzmPb25vo2CMOEwnBhjTH_GTAHeDg_nhlIQ

# Compared vector DB versions in this benchmark (override on demand):
#   Casper v0.1.0 vs Qdrant v1.17.0
CASPER_VERSION ?= v0.1.0
QDRANT_VERSION ?= v1.17.0
CASPER_TARBALL_URL ?= https://github.com/casper-vdb/casper/releases/download/$(CASPER_VERSION)/casper-x86_64-unknown-linux-gnu.tar.gz
QDRANT_TARBALL_URL ?= https://github.com/qdrant/qdrant/releases/download/$(QDRANT_VERSION)/qdrant-x86_64-unknown-linux-gnu.tar.gz
HDF5_URL ?= http://ann-benchmarks.com/deep-image-96-angular.hdf5

# Goose load knobs (forwarded to the goose binary via env).
USERS ?= 32
RUN_TIME_SECONDS ?= 90
SEARCH_LIMITS ?= 10 100 1000 10000 100000
EF_SEARCH ?= 10 100 1000 10000 100000

# Optional NUMA pinning for multi-socket boxes. Empty = no pinning. Example
# for a 2-socket EPYC: SERVER_NUMA_NODE=1 LOAD_NUMA_NODE=0 (server on
# socket 1, goose+import on socket 0 so the generator doesn't steal CPU
# from the server under test).
SERVER_NUMA_NODE ?=
LOAD_NUMA_NODE ?=

.PHONY: build-tools download-dataset-deep-image-96-angular.hdf5 download-casper download-qdrant download-binaries package-linux bench-casper bench-qdrant clean help

help:
	@echo "Targets:"
	@echo "  build-tools    — compile local Rust binaries in ./import and ./goose"
	@echo "  download-dataset-deep-image-96-angular.hdf5 — download deep-image-96-angular.hdf5"
	@echo "  download-casper — download/update ./casper/casper binary"
	@echo "  download-qdrant — download/update ./qdrant/qdrant binary"
	@echo "  download-binaries — download/update both server binaries"
	@echo "  package-linux  — build tools + binaries and create *-unknown-linux-gnu.tar.gz"
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
	@echo "  SERVER_NUMA_NODE=$(SERVER_NUMA_NODE)  (empty = no pinning)"
	@echo "  LOAD_NUMA_NODE=$(LOAD_NUMA_NODE)    (empty = no pinning)"
	@echo "  CASPER_VERSION=$(CASPER_VERSION)"
	@echo "  QDRANT_VERSION=$(QDRANT_VERSION)"
	@echo "  HDF5_URL=$(HDF5_URL)"
	@echo "  DIST_ARCHIVE=$(DIST_ARCHIVE)"

build-tools:
	$(MAKE) -C $(HERE)/import build
	$(MAKE) -C $(HERE)/goose build

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

package-linux: download-binaries build-tools
	@echo "Packing $(DIST_ARCHIVE)"
	@tmp_archive="$(HERE)/../.$(DIST_ARCHIVE).tmp"; \
		rm -f "$$tmp_archive"; \
		tar -C "$(HERE)/.." -czf "$$tmp_archive" \
			--exclude="vector-db-benchmark/.git" \
			--exclude="vector-db-benchmark/.idea" \
			--exclude="vector-db-benchmark/results" \
			--exclude="vector-db-benchmark/.tools" \
			--exclude="vector-db-benchmark/target" \
			--exclude="vector-db-benchmark/*/target" \
			"vector-db-benchmark"; \
		mv -f "$$tmp_archive" "$(HERE)/$(DIST_ARCHIVE)"
	@echo "Archive created: $(HERE)/$(DIST_ARCHIVE)"

bench-casper:
	@HDF5=$(HDF5) RESULTS_DIR=$(RESULTS_DIR) API_TOKEN=$(API_TOKEN) \
	 USERS=$(USERS) RUN_TIME_SECONDS=$(RUN_TIME_SECONDS) \
	 SEARCH_LIMITS="$(SEARCH_LIMITS)" \
	 EF_SEARCH="$(EF_SEARCH)" \
	 SERVER_NUMA_NODE="$(SERVER_NUMA_NODE)" \
	 LOAD_NUMA_NODE="$(LOAD_NUMA_NODE)" \
	 ./scripts/bench_casper.sh

bench-qdrant:
	@HDF5=$(HDF5) RESULTS_DIR=$(RESULTS_DIR) \
	 USERS=$(USERS) RUN_TIME_SECONDS=$(RUN_TIME_SECONDS) \
	 SEARCH_LIMITS="$(SEARCH_LIMITS)" \
	 EF_SEARCH="$(EF_SEARCH)" \
	 SERVER_NUMA_NODE="$(SERVER_NUMA_NODE)" \
	 LOAD_NUMA_NODE="$(LOAD_NUMA_NODE)" \
	 ./scripts/bench_qdrant.sh

clean:
	rm -rf $(RESULTS_DIR) ./casper/storage ./qdrant/storage ./qdrant/snapshots
