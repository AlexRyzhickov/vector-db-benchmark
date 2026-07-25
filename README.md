# Vector DB Benchmark

This repository is a high-load benchmark harness for Casper and Qdrant. Compared versions: Casper `v0.1.0` vs Qdrant `v1.17.0`. The load-testing layer in this project is built on top of the [Goose](https://github.com/tag1consulting/goose) library.

All logs and benchmark outputs are saved under `results/`.

## Download and Extract

1) Download the release archive:

```bash
wget https://github.com/AlexRyzhickov/vector-db-benchmark/releases/download/v0.1.2/vector-db-benchmark-unknown-linux-gnu.tar.gz
```

2) Extract:

```bash
tar -xzf vector-db-benchmark-unknown-linux-gnu.tar.gz
```

3) Go to the project directory:

```bash
cd vector-db-benchmark
```

4) Download dataset:

```bash
# Alternative: make download-dataset-deep-image-96-angular.hdf5

wget http://ann-benchmarks.com/deep-image-96-angular.hdf5
```


## Run Benchmarks

Casper:

```bash
make bench-casper
```

Qdrant:

```bash
make bench-qdrant
```

## Run Benchmarks with Advanced Parameters

### NUMA Pinning

Casper:

```bash
make bench-casper SERVER_NUMA_NODE=1 LOAD_NUMA_NODE=0
```

Qdrant:

```bash
make bench-qdrant SERVER_NUMA_NODE=1 LOAD_NUMA_NODE=0
```

### Concurrency Examples

Casper (higher concurrency):

```bash
make bench-casper USERS=64
```

Qdrant (higher concurrency):

```bash
make bench-qdrant USERS=64
```

Casper (higher concurrency + NUMA pinning):

```bash
make bench-casper USERS=64 SERVER_NUMA_NODE=1 LOAD_NUMA_NODE=0
```

Qdrant (higher concurrency + NUMA pinning):

```bash
make bench-qdrant USERS=64 SERVER_NUMA_NODE=1 LOAD_NUMA_NODE=0
```

### Overrides Example

- `HDF5` — path to the input dataset file used for import and query pool generation.
- `USERS` — number of concurrent Goose virtual users (load level).
- `RUN_TIME_SECONDS` — duration of each benchmark run in seconds.
- `SEARCH_LIMITS` — list of `k` values (`top-k`) to benchmark sequentially.

```bash
make bench-casper \
  HDF5=./deep-image-96-angular.hdf5 \
  USERS=32 \
  RUN_TIME_SECONDS=90 \
  SEARCH_LIMITS="10 100 1000 10000 100000"
```

## Prerequisites

- Bash, `curl`, `make`
- Optional: Rust toolchain (`cargo`) (only needed to build helper binaries from source)
- Optional: `numactl` (for NUMA pinning)
- Dataset file (default): `deep-image-96-angular.hdf5` in this directory
