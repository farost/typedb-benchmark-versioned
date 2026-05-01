# HTTP TPC-C-like benchmark for TypeDB

Single-tool, driver-free benchmark that hits TypeDB's HTTP API directly. The
same script works against any TypeDB build with a v1 HTTP API — including
both `master` and `cluster-support-feature-branch` — without rebuilding the
client.

## Why

The pytpcc harness in this repo measures the full stack including the
TypeDB Python driver. When the driver itself changes (e.g. between master
and cluster-support-feature-branch), comparing the two becomes confounded.
This tool isolates the **server**: you run the same script against two
different server builds with no driver in the loop.

## What it does

A simplified TPC-C-style mix:

| Op | Type | Description |
|---|---|---|
| `NewOrder` | write | match a customer + an item, decrement that item's stock, insert a `purchase` relation. Read-then-write pattern. |
| `Payment`  | write | match a customer's `balance`, delete-and-reinsert with new value. Pure write. |
| `Stock`    | read  | read 5 random items by id. Pure read. |

Default mix: 50 / 30 / 20. Configurable via `--mix N,P,S` percentages.

Schema:

```
attribute id, value integer;
attribute name, value string;
attribute price, value double;
attribute stock, value integer;
attribute balance, value double;
attribute amount, value double;

entity warehouse owns id, owns name;
entity item      owns id, owns name, owns price, owns stock;
entity customer  owns id, owns name, owns balance;

relation purchase
  relates buyer @card(0..1),
  relates product @card(0..),
  owns amount;
customer plays purchase:buyer;
item     plays purchase:product;
```

## Requirements

```
pip install requests
```

That's it. Python 3.8+ stdlib + `requests`.

## Usage

```
./bench.py [OPTIONS]
```

Common knobs:

| Option | Default | Description |
|---|---|---|
| `--addr` | `http://127.0.0.1:8000` | TypeDB HTTP endpoint (incl. scheme + port) |
| `--user` / `--password` | `admin` / `password` | sign-in credentials |
| `--database` | `httpbench` | DB name to use |
| `--clients` | `4` | concurrent worker threads |
| `--duration` | `60` | seconds to run |
| `--warehouses` | `1` | scale knob (multiplies items/customers) |
| `--items-per-warehouse` | `200` | scale knob |
| `--customers-per-warehouse` | `50` | scale knob |
| `--mix` | `50,30,20` | NewOrder, Payment, Stock percentages |
| `--reset` | off | drop the DB before loading |
| `--no-load` | off | skip schema + seed (assume DB already populated) |
| `--load-only` | off | seed and exit, no benchmark |
| `--seed` | `0` | deterministic rng seed (0 = nondeterministic) |
| `--label` | (none) | string baked into JSON for later comparison |
| `--out FILE` | (stdout-only) | write JSON summary to FILE |

## Quick start

```bash
pip install requests

# Start a TypeDB server (master), then in another shell:
./bench.py --addr http://127.0.0.1:8000 --reset \
           --clients 4 --duration 60 \
           --label master --out results/master.json

# Switch to cluster-support-feature-branch, restart server:
./bench.py --addr http://127.0.0.1:8000 --reset \
           --clients 4 --duration 60 \
           --label cluster --out results/cluster.json

# Compare:
./compare.py results/master.json results/cluster.json
```

## Server-port mapping

Mode 3 in this benchmark suite (NEW Core) listens HTTP on port `8000` by
default (see `configs/new_server.yml.template`). For master, you'll need
to start the server with HTTP enabled — the default config exposes HTTP.
Confirm with `curl http://127.0.0.1:8000/v1/health` — should return 200.

If you're using the existing harness's mode3 setup, the running server is
already configured with HTTP at `:8000`. Just don't run `benchmark.sh`
concurrently — bench.py and benchmark.sh would fight over the same DB.

## Multiple configurations

The bench is designed to sweep configurations easily. Example: scan client
counts.

```bash
for clients in 1 2 4 8 16; do
    ./bench.py --addr http://127.0.0.1:8000 --no-load \
               --clients $clients --duration 30 \
               --label "${clients}c" \
               --out "results/scan-clients-${clients}.json"
done

./compare.py results/scan-clients-*.json
```

Other easy sweeps:

- **Mix sensitivity** — `--mix 90,5,5` (write-heavy) vs `--mix 5,5,90` (read-heavy).
- **Scale** — `--warehouses 4 --items-per-warehouse 1000`.
- **Concurrency vs latency** — combine `--clients` and `--duration`.

## Comparing master vs cluster-support-feature-branch

Two-step recipe:

```bash
# Pre-build both server binaries to your bench harness slots:
#   bin/mode3/server_a   — master build
#   bin/mode3/server_b   — cluster-support-feature-branch build

# Run with master server
./bin/mode3/server_a --config configs/generated/mode3.yml --development-mode.enabled true &
SERVER_PID=$!
sleep 6

./http-bench/bench.py --reset --clients 4 --duration 60 \
                      --label master --out /tmp/http-master.json

kill $SERVER_PID; wait 2>/dev/null

# Run with cluster server
./bin/mode3/server_b --config configs/generated/mode3.yml --development-mode.enabled true &
SERVER_PID=$!
sleep 6

./http-bench/bench.py --reset --clients 4 --duration 60 \
                      --label cluster --out /tmp/http-cluster.json

kill $SERVER_PID; wait 2>/dev/null

# Compare
./http-bench/compare.py /tmp/http-master.json /tmp/http-cluster.json
```

## Output

`bench.py --out file.json` produces:

```json
{
  "config": { "addr": "...", "clients": 4, ... },
  "elapsed_seconds": 60.05,
  "results": {
    "new_order": { "ok": 1234, "err": 0, "ops_per_sec": 20.5, "avg_latency_ms": 12.3 },
    "payment":   { ... },
    "stock":     { ... },
    "total_ok": 4567,
    "total_err": 0,
    "total_ops_per_sec": 76.0
  },
  "label": "master"
}
```

Compare two with `compare.py` — prints a side-by-side table with `Δ vs first`
percentages on the right.

## Limitations / things the tool deliberately does NOT do

- No latency percentiles (only mean). Adding p50/p95/p99 is a few lines if you
  need it — accumulate latencies per worker and merge.
- No sustained-load curves (does not vary load over time).
- No isolation/contention testing (each worker uses one-shot transactions —
  it doesn't keep long-lived transactions open).
- No correctness checks (does not verify that NewOrder actually decremented
  stock, etc.).
- The schema is intentionally smaller than full TPC-C — the goal is to
  exercise the read+write commit path, not to match the TPC-C spec.

If you need any of these, extend `bench.py`. The transaction functions
(`tx_new_order`, `tx_payment`, `tx_stock`) are pure thin wrappers; adding a
fourth one is ~10 lines.
