# Baseline Benchmark Results (2026-02-25)

Machine: same host for all runs. Config: 2 clients, 1 warehouse, scalefactor=100, 120s per run.

## Summary Table

| Config | Binary | Nodes | Runs | Mean tpmC | Median | Min | Max | Std Dev | Notes |
|--------|--------|-------|------|-----------|--------|-----|-----|---------|-------|
| Mode 1 — OLD Core (master) | typedb_server | 1 | 5 | **735.4** | 728 | 638 | 801 | 59 | Reference baseline |
| Mode 2 — OLD Cluster 1-node (master) | typedb_server_baseline | 1 | 10 | 178.9 | 165.0 | 135.9 | 267.5 | 43 | Very high variance |
| Mode 2 — OLD Cluster 1-node (master) | typedb_server_optimized | 1 | 10 | **283.8** | 285.7 | 253.9 | 317.0 | 18 | 1.6x faster than baseline |
| Mode 3 — NEW Cluster 3-node (feature) | typedb_server_optimized | 3 | 9/10 | 243.9 | 245.1 | 222.5 | 279.0 | 19 | 1 timeout, run A |
| Mode 3 — NEW Cluster 3-node (feature) | typedb_server_optimized | 3 | 9 | 241.9 | 239.7 | 215.6 | 288.7 | 21 | Run B |
| Mode 3 — NEW Cluster 3-node (feature) | typedb_server_optimized | 3 | 7 | 248.9 | 240.9 | 236.9 | 278.4 | 14 | Run C |
| Mode 3 — NEW Cluster 3-node (feature) | typedb_server_baseline | 3 | — | — | — | — | — | — | Timeouts, unusable |

## Relative Performance (vs Mode 1 Core baseline = 1.0x)

| Config | Mean tpmC | Relative | Slowdown |
|--------|-----------|----------|----------|
| Mode 1 — Core (master) | 735.4 | 1.00x | — |
| Mode 2 — Cluster 1-node optimized (master) | 283.8 | 0.39x | 2.6x slower |
| Mode 2 — Cluster 1-node baseline (master) | 178.9 | 0.24x | 4.1x slower |
| Mode 3 — Cluster 3-node optimized (feature) avg | 244.9 | 0.33x | 3.0x slower |

## Key Observations

1. **Core vs Cluster overhead**: Even single-node cluster (mode 2 optimized) is ~2.6x slower than core — the Raft/clustering machinery has significant overhead even with 1 node.

2. **Optimized vs baseline binary**: Mode 2 optimized (283.8) vs baseline (178.9) = **1.6x improvement** from optimization. Baseline also has very high variance (std dev 43 vs 18).

3. **1-node vs 3-node cluster**: Mode 2 optimized 1-node (283.8) vs Mode 3 optimized 3-node (244.9) = ~15% additional cost for 3-node replication. Relatively modest given the replication overhead.

4. **3-node stability**: Mode 3 has ~10% chance of timeouts, and performance degrades across runs (first run often best). Suggests resource pressure or state accumulation.

5. **New feature branch baseline**: Completely unusable — all timeouts. Only the optimized binary produces results.

## Raw Data

### Mode 1 — OLD Core (master), 5 runs
```
tpmC: 801, 786, 728, 638, 724
```

### Mode 2 — OLD Cluster 1-node baseline (master), 10 runs
```
tpmC: 267.49, 185.77, 154.86, 150.09, 137.46, 235.71, 192.95, 174.99, 153.93, 135.88
```

### Mode 2 — OLD Cluster 1-node optimized (master), 10 runs
```
tpmC: 317.00, 293.34, 293.98, 274.96, 289.91, 294.57, 264.88, 273.82, 281.36, 253.93
```

### Mode 3 — NEW Cluster 3-node optimized (feature), run A — 9/10 runs (1 timeout)
```
tpmC: 279.0, 249.5, TIMEOUT, 264.9, 245.1, 228.7, 228.3, 223.7, 222.5, 253.6
```

### Mode 3 — NEW Cluster 3-node optimized (feature), run B — 9 runs
```
tpmC: 288.7, 251.1, 241.9, 234.8, 223.8, 239.7, 229.6, 215.6, 251.3
```

### Mode 3 — NEW Cluster 3-node optimized (feature), run C — 7 runs
```
tpmC: 278.4, 239.6, 260.1, 248.1, 236.9, 238.8, 240.9
```

## Test Configuration Reference

```
Benchmark: TPC-C
Clients: 2
Warehouses: 1
Scale factor: 100
Duration: 120s per run
Runs: 10 (unless noted)
Development mode: enabled
```

### Mode mapping (old scripts → new benchmark package)

| Old script name | New mode | Description |
|-----------------|----------|-------------|
| mode1 | mode1 | OLD Core (typedb master, 1 node) |
| mode2-baseline | mode4 a | NEW Cluster binary, 1 node, baseline build |
| mode2-optimized | mode4 a | NEW Cluster binary, 1 node, optimized build |
| mode3-baseline | mode5 a | NEW Cluster 3-node, baseline build |
| mode3-optimized | mode5 a | NEW Cluster 3-node, optimized build |
