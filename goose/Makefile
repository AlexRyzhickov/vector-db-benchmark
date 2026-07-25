PACKAGE := goose-load-test
BIN := goose-load-test
HERE := $(CURDIR)
CARGO_TARGET_DIR := $(HERE)/target
TARGET_DIR := $(CARGO_TARGET_DIR)/release

HOST ?= http://localhost:7222
CASPER_COLLECTION ?= test_collection
POOL_SIZE ?= 100000
SEARCH_LIMIT ?= 10
BENCH_SLEEP ?= 15
OUTPUT_FORMAT ?= bin

BIN_POOL_PATH ?= /root/dir/perf/data.bin
HDF5_POOL_PATH ?= /root/dir/perf/deep-image-96-angular.hdf5

# Qdrant-specific overrides (gRPC endpoint, used by qdrant-client)
QDRANT_URL         ?= http://localhost:6334
QDRANT_COLLECTION  ?= deep-image-96-noindex
HNSW_EF            ?= 128

.PHONY: build clean run-bin run-hdf5 run-hdf5-qdrant bench-bin bench-hdf5 bench-hdf5-qdrant

build:
	cargo build --manifest-path $(HERE)/Cargo.toml --release --target-dir $(CARGO_TARGET_DIR)
	cp $(TARGET_DIR)/$(BIN) $(HERE)/$(BIN)

clean:
	rm -f $(HERE)/$(BIN)

run-bin: $(HERE)/$(BIN)
	POOL_SOURCE=bin \
		POOL_PATH=$(BIN_POOL_PATH) \
		POOL_SIZE=$(POOL_SIZE) \
		SEARCH_LIMIT=$(SEARCH_LIMIT) \
		CASPER_COLLECTION=$(CASPER_COLLECTION) \
		OUTPUT_FORMAT=$(OUTPUT_FORMAT) \
		$(HERE)/$(BIN) --host $(HOST)

run-hdf5: $(HERE)/$(BIN)
	POOL_SOURCE=hdf5 \
		POOL_PATH=$(HDF5_POOL_PATH) \
		POOL_SIZE=$(POOL_SIZE) \
		SEARCH_LIMIT=$(SEARCH_LIMIT) \
		CASPER_COLLECTION=$(CASPER_COLLECTION) \
		OUTPUT_FORMAT=$(OUTPUT_FORMAT) \
		$(HERE)/$(BIN) --host $(HOST)

$(HERE)/$(BIN):
	$(MAKE) build

bench-bin: $(HERE)/$(BIN)
	@first=1; for k in 10 100 1000; do \
		if [ $$first -eq 0 ]; then echo ">>> sleep $(BENCH_SLEEP)s"; sleep $(BENCH_SLEEP); fi; \
		echo ">>> run-bin SEARCH_LIMIT=$$k"; \
		$(MAKE) --no-print-directory run-bin SEARCH_LIMIT=$$k || exit $$?; \
		first=0; \
	done

bench-hdf5: $(HERE)/$(BIN)
	@first=1; for k in 10 100 1000 10000 100000; do \
		if [ $$first -eq 0 ]; then echo ">>> sleep $(BENCH_SLEEP)s"; sleep $(BENCH_SLEEP); fi; \
		echo ">>> run-hdf5 SEARCH_LIMIT=$$k"; \
		$(MAKE) --no-print-directory run-hdf5 SEARCH_LIMIT=$$k || exit $$?; \
		first=0; \
	done

# Same as run-hdf5 but targets a Qdrant instance via the official qdrant-client (gRPC).
# Requires QDRANT_COLLECTION and HNSW_EF; QDRANT_URL points at Qdrant's gRPC port (6334).
run-hdf5-qdrant: $(HERE)/$(BIN)
	BACKEND=qdrant \
		POOL_SOURCE=hdf5 \
		POOL_PATH=$(HDF5_POOL_PATH) \
		POOL_SIZE=$(POOL_SIZE) \
		SEARCH_LIMIT=$(SEARCH_LIMIT) \
		OUTPUT_FORMAT=$(OUTPUT_FORMAT) \
		HNSW_EF=$(HNSW_EF) \
		QDRANT_URL=$(QDRANT_URL) \
		QDRANT_COLLECTION=$(QDRANT_COLLECTION) \
		$(HERE)/$(BIN) --host $(QDRANT_URL)

bench-hdf5-qdrant: $(HERE)/$(BIN)
	@first=1; for k in 10 100 1000 10000 100000; do \
		if [ $$first -eq 0 ]; then echo ">>> sleep $(BENCH_SLEEP)s"; sleep $(BENCH_SLEEP); fi; \
		echo ">>> run-hdf5-qdrant SEARCH_LIMIT=$$k HNSW_EF=$$k"; \
		$(MAKE) --no-print-directory run-hdf5-qdrant SEARCH_LIMIT=$$k HNSW_EF=$$k || exit $$?; \
		first=0; \
	done
