# Bench: end-to-end Casper / Qdrant runs (see scripts/bench_*.sh).
#
# All artifacts (server logs, goose results) end up under $(RESULTS_DIR).
# Server storage directories are wiped before each bench so runs are
# independent.

HDF5 ?= $(HERE)/deep-image-96-angular.hdf5
RESULTS_DIR ?= $(HERE)/results

# Casper license token.
LICENSE_TOKEN ?= eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE4MjU1ODE2NzIsImZyZWUiOnRydWV9.1RW9Q3JyAtc_DiwtAnZA0gfRYWfHTIRusQ57XR3TV_U

# Goose load knobs (forwarded to the goose binary via env).
USERS ?= 32
RUN_TIME_SECONDS ?= 90
SEARCH_LIMITS ?= 10 100 1000 10000 100000
EF_SEARCH ?= 10 100 1000 10000 100000

# Qdrant collection optimizers config knobs.
QDRANT_USE_OPTIMIZERS_CONFIG ?= false
QDRANT_DEFAULT_SEGMENT_NUMBER ?= 1

# Optional NUMA pinning for multi-socket boxes. Empty = no pinning. Example
# for a 2-socket EPYC: SERVER_NUMA_NODE=1 LOAD_NUMA_NODE=0 (server on
# socket 1, goose+import on socket 0 so the generator doesn't steal CPU
# from the server under test).
SERVER_NUMA_NODE ?=
LOAD_NUMA_NODE ?=

.PHONY: bench-casper bench-qdrant clean

bench-casper: $(CASPER_BIN) $(IMPORT_BIN) $(GOOSE_BIN)
	@HDF5=$(HDF5) RESULTS_DIR=$(RESULTS_DIR) LICENSE_TOKEN=$(LICENSE_TOKEN) \
	 USERS=$(USERS) RUN_TIME_SECONDS=$(RUN_TIME_SECONDS) \
	 SEARCH_LIMITS="$(SEARCH_LIMITS)" \
	 EF_SEARCH="$(EF_SEARCH)" \
	 SERVER_NUMA_NODE="$(SERVER_NUMA_NODE)" \
	 LOAD_NUMA_NODE="$(LOAD_NUMA_NODE)" \
	 ./scripts/bench_casper.sh

bench-qdrant: $(QDRANT_BIN) $(IMPORT_BIN) $(GOOSE_BIN)
	@HDF5=$(HDF5) RESULTS_DIR=$(RESULTS_DIR) \
	 USERS=$(USERS) RUN_TIME_SECONDS=$(RUN_TIME_SECONDS) \
	 SEARCH_LIMITS="$(SEARCH_LIMITS)" \
	 EF_SEARCH="$(EF_SEARCH)" \
	 SERVER_NUMA_NODE="$(SERVER_NUMA_NODE)" \
	 LOAD_NUMA_NODE="$(LOAD_NUMA_NODE)" \
	 QDRANT_USE_OPTIMIZERS_CONFIG="$(QDRANT_USE_OPTIMIZERS_CONFIG)" \
	 QDRANT_DEFAULT_SEGMENT_NUMBER="$(QDRANT_DEFAULT_SEGMENT_NUMBER)" \
	 ./scripts/bench_qdrant.sh

clean:
	rm -rf $(RESULTS_DIR) ./casper/storage ./qdrant/storage ./qdrant/snapshots
