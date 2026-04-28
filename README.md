# TypeDB TPC-C Benchmark Package

Performance benchmarking for TypeDB Core and Cluster using the [TPC-C](http://www.tpc.org/tpcc/) workload,
based on [typedb/typedb-benchmark](https://github.com/typedb/typedb-benchmark/tree/development/tpcc).

## Modes

| Mode | Server | Driver | Description |
|------|--------|--------|-------------|
| **mode1** | `typedb` master (3.10.x release) | `pip install typedb-driver` | OLD Core — single server, no clustering |
| **mode2** | `typedb-cluster` master (3.10.x release) | `pip install typedb-driver` | OLD Cluster — 3-node clustering (old architecture) |
| **mode3** | `typedb` cluster-support-feature-branch | Local build | NEW Core — single server from new codebase |
| **mode4** | `typedb-cluster` cluster-support-feature-branch | Local build | NEW Cluster — single server (cluster binary overhead test) |
| **mode5** | `typedb-cluster` cluster-support-feature-branch | Local build | NEW Cluster — 3-node with admin registration |

Each mode supports two binary slots (**A** and **B**) for A/B comparison (e.g., baseline vs optimized).

## Quick Start

```bash
# 1. Setup Python environment
./setup.sh old                              # Modes 1 & 2 (pip-installed driver)
./setup.sh new /path/to/driver.whl          # Modes 3, 4, 5 (local-built driver)

# 2. Place server binaries
cp /path/to/typedb_server bin/mode1/server_a

# 3. Run benchmark
./benchmark.sh mode1 a 5 120                # 5 runs × 120s

# 4. Compare variants
./benchmark.sh mode2 compare 3 60           # Run A then B, print diff
./compare.sh logs/results/file_a.txt logs/results/file_b.txt  # Compare saved results
```

## Usage

```
./benchmark.sh MODE VARIANT [RUNS] [DURATION]
```

| Argument | Values | Default | Description |
|----------|--------|---------|-------------|
| `MODE` | `mode1` `mode2` `mode3` `mode4` `mode5` | required | Which configuration to benchmark |
| `VARIANT` | `a` `b` `compare` | required | Which binary or comparison mode |
| `RUNS` | integer | `5` | Number of benchmark iterations |
| `DURATION` | seconds | `120` | Seconds per iteration |

**Environment variables** for fine-tuning:

| Variable | Default | Description |
|----------|---------|-------------|
| `CLIENTS` | `2` | Parallel TPC-C worker processes |
| `WAREHOUSES` | `1` | TPC-C warehouse count |
| `SCALEFACTOR` | `100` | TPC-C scale factor (100 = 1/100th of full TPC-C) |
| `CLUSTER_NODES` | `3` | Number of cluster nodes (modes 2, 5) |

**Examples:**

```bash
# Quick test (short runs)
./benchmark.sh mode1 a 2 30

# Full benchmark
./benchmark.sh mode1 a 5 120

# Compare baseline vs optimized on cluster
./benchmark.sh mode5 compare 5 120

# High concurrency test
CLIENTS=8 WAREHOUSES=4 ./benchmark.sh mode3 a 3 60
```

## Setup Per Mode

### Mode 1 — OLD Core

**Driver:** Released `typedb-driver` from PyPI.

```bash
./setup.sh old
```

**Server binary:** Download from [TypeDB releases](https://github.com/typedb/typedb/releases) (3.10.x) or
build from source:

```bash
cd typedb
git checkout master      # or tag 3.10.x
bazel build //:assemble-typedb-all --compilation_mode=opt
# Binary: bazel-bin/typedb_server
cp bazel-bin/typedb_server /path/to/benchmark_package/bin/mode1/server_a
```

### Mode 2 — OLD Cluster

**Driver:** Same as mode 1 (`pip install typedb-driver`).

```bash
./setup.sh old
```

**Server binary:** Build from `typedb-cluster` master:

```bash
cd typedb-cluster
git checkout master
bazel build //:assemble-typedb-all --compilation_mode=opt
cp bazel-bin/typedb_server /path/to/benchmark_package/bin/mode2/server_a
# For comparison: build with optimization and copy as server_b
cp bazel-bin/typedb_server /path/to/benchmark_package/bin/mode2/server_b
```

### Mode 3 — NEW Core

**Driver:** Built locally from `cluster-support-feature-branch`.

```bash
cd typedb-driver
git checkout cluster-support-feature-branch
bazel build //python:assemble-pip311    # adjust for your Python version (39/310/311/312/313)
ls bazel-bin/python/*.whl               # find the wheel
./setup.sh new /path/to/typedb_driver-*.whl
```

**Server binary:**

```bash
cd typedb
git checkout cluster-support-feature-branch
bazel build //:assemble-typedb-all --compilation_mode=opt
cp bazel-bin/typedb_server /path/to/benchmark_package/bin/mode3/server_a
```

### Mode 4 — NEW Cluster (single node)

Runs the cluster binary as a single server (no peer registration). Useful for measuring the
overhead of the cluster binary vs the core binary (mode 3 vs mode 4).

**Driver:** Same as mode 3 (locally-built wheel).

```bash
./setup.sh new /path/to/typedb_driver-*.whl
```

**Server binary:**

```bash
cd typedb-cluster
git checkout cluster-support-feature-branch
bazel build //:assemble-typedb-all --compilation_mode=opt
cp bazel-bin/typedb_server /path/to/benchmark_package/bin/mode4/server_a
```

### Mode 5 — NEW Cluster (3-node, admin registration)

Full 3-node cluster using the new architecture. Nodes are started individually, then
replicas 2 and 3 are registered on node 1 via the **admin tool**.

**Driver:** Same as mode 3 (locally-built wheel).

```bash
./setup.sh new /path/to/typedb_driver-*.whl
```

**Server + admin binaries:**

```bash
cd typedb-cluster
git checkout cluster-support-feature-branch
bazel build //:assemble-typedb-all --compilation_mode=opt

# Server binary
cp bazel-bin/typedb_server /path/to/benchmark_package/bin/mode5/server_a

# Admin tool (from the distribution archive)
cp bazel-bin/admin/typedb_admin_bin /path/to/benchmark_package/bin/mode5/admin
chmod +x /path/to/benchmark_package/bin/mode5/admin
```

**Port scheme (per node N = 1, 2, 3):**

| Port | Formula | Node 1 | Node 2 | Node 3 |
|------|---------|--------|--------|--------|
| Admin | N×10000+1728 | 11728 | 21728 | 31728 |
| gRPC | N×10000+1729 | 11729 | 21729 | 31729 |
| Clustering | N×10000+1730 | 11730 | 21730 | 31730 |
| Monitoring | N×10000+1731 | 11731 | 21731 | 31731 |
| HTTP | N×10000+8000 | 18000 | 28000 | 38000 |

## Building Production Binaries

For accurate benchmark results, always build with **optimization flags**:

```bash
# Rust/Bazel — production mode
bazel build //:assemble-typedb-all --compilation_mode=opt

# Verify it's a release build (no debug symbols)
file bazel-bin/typedb_server
# Should show: "ELF 64-bit LSB executable ... not stripped" (opt) or "stripped"
```

Never benchmark debug builds (`--compilation_mode=dbg` or default `fastbuild`).

## Comparing Results

### Inline comparison

```bash
./benchmark.sh mode2 compare 5 120
```

This runs variant A then B and prints a side-by-side diff:

```
┌──────────────────────────────────────────────────────────┐
│  COMPARISON                                              │
├──────────────────────────────────────────────────────────┤
│  A (baseline)   avg 515.20  tpmC  [510.3 520.1 ...]
│  B (optimized)  avg 630.50  tpmC  [625.0 636.0 ...]
├──────────────────────────────────────────────────────────┤
│  Delta: +115.30 tpmC (+22.4%)  ▲ B (optimized) is FASTER
└──────────────────────────────────────────────────────────┘
```

### File-based comparison

All results are saved in `logs/results/` with timestamps. Compare any two:

```bash
./compare.sh logs/results/mode2_a_20260427_143200.txt \
             logs/results/mode4_a_20260427_153000.txt
```

This lets you compare across modes (e.g., old cluster vs new cluster).

### Cross-mode comparison

To compare old core vs new core performance:

```bash
./benchmark.sh mode1 a 5 120    # Saves result file
./benchmark.sh mode3 a 5 120    # Saves result file
./compare.sh logs/results/mode1_a_*.txt logs/results/mode3_a_*.txt
```

## Switching Driver Versions

**OLD driver (modes 1 & 2):**
```bash
source venvs/old/bin/activate
pip install typedb-driver==3.10.0    # specific version
deactivate
```

**NEW driver (modes 3, 4, 5):**
```bash
source venvs/new/bin/activate
pip install /path/to/new_wheel.whl --force-reinstall
deactivate
```

## Updating Binaries

Just overwrite the file in `bin/modeN/`:

```bash
cp bazel-bin/typedb_server bin/mode4/server_a
chmod +x bin/mode4/server_a
```

## Directory Structure

```
├── benchmark.sh              # Main entry point
├── setup.sh                  # Environment setup
├── compare.sh                # Result comparison tool
├── README.md
├── bin/                      # Server binaries (user-provided)
│   ├── mode1/                #   server_a [, server_b]
│   ├── mode2/
│   ├── mode3/
│   ├── mode4/
│   └── mode5/                #   server_a [, server_b] + admin
├── modes/                    # Mode-specific scripts
│   ├── common.sh             #   Shared functions
│   ├── mode1.sh              #   OLD Core
│   ├── mode2.sh              #   OLD Cluster (3-node)
│   ├── mode3.sh              #   NEW Core
│   ├── mode4.sh              #   NEW Cluster (1-node)
│   └── mode5.sh              #   NEW Cluster (3-node, admin registration)
├── configs/                  # Configuration templates
│   ├── core.yml.template     #   Old-branch server config (modes 1, 2)
│   ├── cluster_node.yml.template  # Old-branch cluster config (mode 2)
│   ├── new_server.yml.template    # New-branch server config (modes 3, 4, 5)
│   ├── generated/            #   Runtime-generated (gitignored)
│   └── tpcc/
│       ├── core.cfg          #   TPC-C config for core modes (1, 3, 4)
│       ├── cluster.cfg       #   TPC-C config for old cluster (mode 2)
│       └── cluster_new.cfg   #   TPC-C config for new cluster (mode 5)
├── venvs/                    # Python virtual environments
│   ├── old/                  #   Modes 1 & 2
│   └── new/                  #   Modes 3, 4, 5
├── data/                     # Database storage (runtime)
├── logs/                     # Server logs
│   └── results/              #   Benchmark result files
└── pytpcc/                   # TPC-C benchmark code
    ├── tpcc.py               #   Main runner (upstream-identical)
    ├── constants.py
    ├── drivers/
    │   ├── abstractdriver.py
    │   ├── typedb3driver.py         # Core driver
    │   ├── typedb3clusterdriver.py  # Cluster driver (inherits from Core)
    │   └── tql3/tpcc-schema.tql
    ├── runtime/
    │   ├── executor.py
    │   └── loader.py
    └── util/
        ├── results.py
        ├── scaleparameters.py
        ├── nurand.py
        └── rand.py
```

## TPC-C Benchmark Details

The benchmark implements the standard TPC-C workload:

| Transaction | Weight | Description |
|-------------|--------|-------------|
| NEW_ORDER | 45% | Create new orders with items |
| PAYMENT | 43% | Customer payments |
| ORDER_STATUS | 4% | Query order status |
| DELIVERY | 4% | Deliver orders |
| STOCK_LEVEL | 4% | Stock level checks |

**tpmC** = new_order_count × 60 / duration_seconds

## Troubleshooting

**Server fails to start:** Check `logs/modeN_variant.log`. Common issues:
- Port already in use: `pkill -f typedb_server`
- Binary not found: `ls -la bin/modeN/`
- Wrong permissions: `chmod +x bin/modeN/server_a`

**Driver not found:** Run `./setup.sh` for the right generation:
- Modes 1 & 2: `./setup.sh old`
- Modes 3, 4, 5: `./setup.sh new /path/to/wheel.whl`

**Low tpmC:** Ensure release builds (`--compilation_mode=opt`), no other load on machine.

**Cluster formation timeout:** Increase `sleep 20` in `modes/mode2.sh` or `sleep 10` in `modes/mode5.sh`.

**Admin registration fails (mode 5):** Increase `REGISTER_MAX_RETRIES` or `REGISTER_RETRY_INTERVAL`
in `modes/mode5.sh`. Ensure the admin binary is at `bin/mode5/admin` and is executable.
