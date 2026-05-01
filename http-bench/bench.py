#!/usr/bin/env python3
"""
HTTP TPC-C-like benchmark for TypeDB.

Talks to a TypeDB server's HTTP API directly — no driver dependency, so the
same script benchmarks master and cluster-support-feature-branch with the
same workload code.

Workload (TPC-C inspired, simplified):
  NEW_ORDER  (write) — match a customer + an item, decrement that item's
                       stock, insert a purchase relation. Read-then-write.
  PAYMENT    (write) — match a customer's balance attribute, delete-and-
                       reinsert with new value. Pure write.
  STOCK      (read)  — read N random items by id (read-only).

Default mix: 50 / 30 / 20. Configurable via --mix.

Usage examples:

  # one-off load + run 5 workers for 60s, default mix
  ./bench.py --addr http://127.0.0.1:8000 --reset --clients 5 --duration 60

  # already-loaded DB, run only
  ./bench.py --addr http://127.0.0.1:8000 --no-load --clients 8 --duration 120

  # custom mix (NewOrder/Payment/Stock %)
  ./bench.py --mix 60,30,10 --duration 30

Results are written to JSON for cross-run comparison; see compare.py.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass, field
from typing import Optional

try:
    import requests
except ImportError:
    sys.stderr.write("ERROR: this script needs `requests` (pip install requests)\n")
    sys.exit(2)


# ─── Config ────────────────────────────────────────────────────────────────


@dataclass
class Config:
    addr: str = "http://127.0.0.1:8000"
    user: str = "admin"
    password: str = "password"
    database: str = "httpbench"
    clients: int = 4
    duration: float = 60.0
    api_version: str = "v1"
    warehouses: int = 1
    items_per_warehouse: int = 200
    customers_per_warehouse: int = 50
    mix: tuple = (50, 30, 20)            # NEW_ORDER, PAYMENT, STOCK percentages
    request_timeout: float = 30.0
    seed: int = 0


# ─── HTTP client ───────────────────────────────────────────────────────────


class TypeDB:
    """Thin wrapper over the TypeDB HTTP API. One instance per worker thread."""

    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.s = requests.Session()
        self.token: Optional[str] = None

    # path helpers
    def _url(self, path: str) -> str:
        return f"{self.cfg.addr.rstrip('/')}/{self.cfg.api_version}{path}"

    def _hdr(self) -> dict:
        h = {"Content-Type": "application/json"}
        if self.token:
            h["Authorization"] = f"Bearer {self.token}"
        return h

    def signin(self) -> str:
        r = self.s.post(
            f"{self.cfg.addr.rstrip('/')}/{self.cfg.api_version}/signin",
            json={"username": self.cfg.user, "password": self.cfg.password},
            timeout=self.cfg.request_timeout,
        )
        r.raise_for_status()
        self.token = r.json()["token"]
        return self.token

    # database ops
    def db_exists(self, name: str) -> bool:
        r = self.s.get(self._url(f"/databases/{name}"), headers=self._hdr(),
                       timeout=self.cfg.request_timeout)
        return r.status_code == 200

    def db_create(self, name: str) -> None:
        r = self.s.post(self._url(f"/databases/{name}"), headers=self._hdr(),
                        timeout=self.cfg.request_timeout)
        if r.status_code not in (200, 201, 204):
            r.raise_for_status()

    def db_delete(self, name: str) -> None:
        """Idempotent. Different TypeDB branches map missing-DB to different
        HTTP statuses (some 404, some 400), so we existence-check first."""
        if not self.db_exists(name):
            return
        r = self.s.delete(self._url(f"/databases/{name}"), headers=self._hdr(),
                          timeout=self.cfg.request_timeout)
        if r.status_code in (200, 204, 404):
            return
        # Surface the body so we can debug an actual delete failure
        body = (r.text or "")[:300]
        raise requests.HTTPError(
            f"DELETE /databases/{name} returned {r.status_code}: {body}",
            response=r,
        )

    # transaction ops (multi-step)
    def txn_open(self, db: str, type_: str = "Write") -> str:
        r = self.s.post(
            self._url("/transactions/open"),
            headers=self._hdr(),
            json={"databaseName": db, "transactionType": type_},
            timeout=self.cfg.request_timeout,
        )
        r.raise_for_status()
        return r.json()["transactionId"]

    def txn_query(self, txn_id: str, query: str) -> dict:
        r = self.s.post(
            self._url(f"/transactions/{txn_id}/query"),
            headers=self._hdr(),
            json={"query": query},
            timeout=self.cfg.request_timeout,
        )
        r.raise_for_status()
        return r.json()

    def txn_commit(self, txn_id: str) -> None:
        r = self.s.post(
            self._url(f"/transactions/{txn_id}/commit"),
            headers=self._hdr(),
            timeout=self.cfg.request_timeout,
        )
        r.raise_for_status()

    def txn_close(self, txn_id: str) -> None:
        try:
            self.s.post(
                self._url(f"/transactions/{txn_id}/close"),
                headers=self._hdr(),
                timeout=self.cfg.request_timeout,
            )
        except Exception:
            pass

    # one-shot (open+query+commit in a single call)
    def query_oneshot(self, db: str, query: str, type_: str = "Write",
                      commit: bool = True) -> dict:
        r = self.s.post(
            self._url("/query"),
            headers=self._hdr(),
            json={
                "databaseName": db,
                "transactionType": type_,
                "query": query,
                "commit": commit,
            },
            timeout=self.cfg.request_timeout,
        )
        r.raise_for_status()
        return r.json()


# ─── Schema + load ─────────────────────────────────────────────────────────


SCHEMA = """define
  attribute id, value integer;
  attribute name, value string;
  attribute price, value double;
  attribute stock, value integer;
  attribute balance, value double;
  attribute amount, value double;

  entity warehouse owns id, owns name;
  entity item owns id, owns name, owns price, owns stock;
  entity customer owns id, owns name, owns balance;

  relation purchase
    relates buyer @card(0..1),
    relates product @card(0..),
    owns amount;
  customer plays purchase:buyer;
  item plays purchase:product;
"""


def setup_schema(client: TypeDB, db: str) -> None:
    """Run the schema definition. Uses a Schema-type one-shot query."""
    client.query_oneshot(db, SCHEMA, type_="Schema", commit=True)


def seed_data(client: TypeDB, cfg: Config) -> None:
    """Seed warehouses, items, customers in batched insert transactions."""
    print(f"[load] {cfg.warehouses} warehouse(s), "
          f"{cfg.items_per_warehouse} items/wh, "
          f"{cfg.customers_per_warehouse} customers/wh")

    # Insert warehouses (small)
    inserts = ["insert"]
    for w in range(1, cfg.warehouses + 1):
        inserts.append(
            f'$w{w} isa warehouse, has id {w}, has name "wh-{w}";'
        )
    client.query_oneshot(cfg.database, "\n".join(inserts), type_="Write", commit=True)

    # Items — chunked inserts to avoid huge transactions
    item_id = 1
    chunk = 50
    for w in range(1, cfg.warehouses + 1):
        for start in range(0, cfg.items_per_warehouse, chunk):
            ins = ["insert"]
            for k in range(start, min(start + chunk, cfg.items_per_warehouse)):
                price = round(random.uniform(1.0, 100.0), 2)
                stock = random.randint(50, 500)
                ins.append(
                    f'$i{item_id} isa item, has id {item_id}, '
                    f'has name "item-{item_id}", has price {price}, '
                    f'has stock {stock};'
                )
                item_id += 1
            client.query_oneshot(cfg.database, "\n".join(ins), type_="Write", commit=True)

    # Customers — chunked
    cust_id = 1
    for w in range(1, cfg.warehouses + 1):
        for start in range(0, cfg.customers_per_warehouse, chunk):
            ins = ["insert"]
            for k in range(start, min(start + chunk, cfg.customers_per_warehouse)):
                bal = round(random.uniform(100.0, 1000.0), 2)
                ins.append(
                    f'$c{cust_id} isa customer, has id {cust_id}, '
                    f'has name "cust-{cust_id}", has balance {bal};'
                )
                cust_id += 1
            client.query_oneshot(cfg.database, "\n".join(ins), type_="Write", commit=True)

    print(f"[load] inserted {item_id - 1} items, {cust_id - 1} customers.")


# ─── Workload transactions ─────────────────────────────────────────────────


class Random:
    """Per-worker rng so seeds are reproducible. Wraps random.Random."""
    def __init__(self, seed: int):
        self.rng = random.Random(seed)

    def item_id(self, total_items: int) -> int:
        return self.rng.randint(1, total_items)

    def customer_id(self, total_customers: int) -> int:
        return self.rng.randint(1, total_customers)


def tx_new_order(client: TypeDB, cfg: Config, rng: Random,
                 total_items: int, total_customers: int) -> None:
    cust_id = rng.customer_id(total_customers)
    item_id = rng.item_id(total_items)
    decrement = 1
    amount = round(rng.rng.uniform(1.0, 50.0), 2)
    q = f"""
match
  $c isa customer, has id {cust_id};
  $i isa item, has id {item_id}, has stock $old_stock, has price $p;
delete $old_stock of $i;
insert
  $i has stock ($old_stock - {decrement});
  $purchase isa purchase (buyer: $c, product: $i), has amount {amount};
"""
    client.query_oneshot(cfg.database, q, type_="Write", commit=True)


def tx_payment(client: TypeDB, cfg: Config, rng: Random,
               total_customers: int) -> None:
    cust_id = rng.customer_id(total_customers)
    delta = round(rng.rng.uniform(1.0, 20.0), 2)
    q = f"""
match
  $c isa customer, has id {cust_id}, has balance $old_balance;
delete $old_balance of $c;
insert $c has balance ($old_balance + {delta});
"""
    client.query_oneshot(cfg.database, q, type_="Write", commit=True)


def tx_stock(client: TypeDB, cfg: Config, rng: Random, total_items: int) -> None:
    """Read 5 random items by id."""
    ids = [str(rng.item_id(total_items)) for _ in range(5)]
    # Build a match pattern for each item; we read but discard results.
    matches = []
    for k, iid in enumerate(ids):
        matches.append(f"$i{k} isa item, has id {iid}, has stock $s{k};")
    q = "match\n  " + "\n  ".join(matches) + "\nselect $s0, $s1, $s2, $s3, $s4;"
    client.query_oneshot(cfg.database, q, type_="Read", commit=False)


# ─── Worker + coordinator ──────────────────────────────────────────────────


@dataclass
class Stats:
    new_order_ok: int = 0
    new_order_err: int = 0
    new_order_ns: int = 0      # cumulative latency in ns
    payment_ok: int = 0
    payment_err: int = 0
    payment_ns: int = 0
    stock_ok: int = 0
    stock_err: int = 0
    stock_ns: int = 0

    # last error per type for diagnostics
    last_error: dict = field(default_factory=dict)

    def merge(self, other: "Stats") -> None:
        for k in ("new_order_ok", "new_order_err", "new_order_ns",
                  "payment_ok", "payment_err", "payment_ns",
                  "stock_ok", "stock_err", "stock_ns"):
            setattr(self, k, getattr(self, k) + getattr(other, k))
        self.last_error.update(other.last_error)


def worker(idx: int, cfg: Config, total_items: int, total_customers: int,
           stop_at: float, stats: Stats, weights: list) -> None:
    """One client worker: open, signin, loop transactions until stop_at."""
    client = TypeDB(cfg)
    client.signin()
    rng = Random(seed=cfg.seed + idx if cfg.seed else random.randint(1, 2**31))

    while time.monotonic() < stop_at:
        op = rng.rng.choices(["new_order", "payment", "stock"], weights=weights, k=1)[0]
        t0 = time.monotonic_ns()
        try:
            if op == "new_order":
                tx_new_order(client, cfg, rng, total_items, total_customers)
                stats.new_order_ok += 1
                stats.new_order_ns += time.monotonic_ns() - t0
            elif op == "payment":
                tx_payment(client, cfg, rng, total_customers)
                stats.payment_ok += 1
                stats.payment_ns += time.monotonic_ns() - t0
            else:
                tx_stock(client, cfg, rng, total_items)
                stats.stock_ok += 1
                stats.stock_ns += time.monotonic_ns() - t0
        except requests.HTTPError as e:
            err_text = ""
            try:
                err_text = e.response.text[:200]
            except Exception:
                pass
            stats.last_error[op] = f"HTTP {e.response.status_code}: {err_text}"
            if op == "new_order": stats.new_order_err += 1
            elif op == "payment": stats.payment_err += 1
            else:                 stats.stock_err += 1
        except requests.RequestException as e:
            stats.last_error[op] = f"network: {e}"
            if op == "new_order": stats.new_order_err += 1
            elif op == "payment": stats.payment_err += 1
            else:                 stats.stock_err += 1


def run_benchmark(cfg: Config) -> dict:
    total_items = cfg.warehouses * cfg.items_per_warehouse
    total_customers = cfg.warehouses * cfg.customers_per_warehouse

    weights = list(cfg.mix)
    assert sum(weights) > 0, "mix sums to zero"

    print(f"[run] clients={cfg.clients}  duration={cfg.duration}s  "
          f"items={total_items}  customers={total_customers}  mix={cfg.mix}")

    per_worker_stats = [Stats() for _ in range(cfg.clients)]

    started_at = time.monotonic()
    stop_at = started_at + cfg.duration

    with ThreadPoolExecutor(max_workers=cfg.clients) as pool:
        futs = [
            pool.submit(worker, idx, cfg, total_items, total_customers,
                        stop_at, per_worker_stats[idx], weights)
            for idx in range(cfg.clients)
        ]
        # Print rolling progress every 5 s
        last_print = started_at
        while any(not f.done() for f in futs):
            now = time.monotonic()
            if now - last_print >= 5.0:
                agg = Stats()
                for s in per_worker_stats:
                    agg.merge(s)
                elapsed = now - started_at
                tot = (agg.new_order_ok + agg.payment_ok + agg.stock_ok)
                rate = tot / max(elapsed, 1e-9)
                print(f"[ {elapsed:6.1f}s ] "
                      f"NewOrder={agg.new_order_ok}/{agg.new_order_err} "
                      f"Payment={agg.payment_ok}/{agg.payment_err} "
                      f"Stock={agg.stock_ok}/{agg.stock_err} "
                      f"  rate={rate:.1f} ops/s")
                last_print = now
            time.sleep(0.5)

        for f in futs:
            f.result()

    elapsed = time.monotonic() - started_at

    final = Stats()
    for s in per_worker_stats:
        final.merge(s)

    def avg_ms(ns_total: int, n: int) -> float:
        return (ns_total / n / 1_000_000) if n > 0 else 0.0

    summary = {
        "config": {k: list(v) if isinstance(v, tuple) else v
                   for k, v in asdict(cfg).items()},
        "elapsed_seconds": elapsed,
        "results": {
            "new_order": {
                "ok": final.new_order_ok,
                "err": final.new_order_err,
                "ops_per_sec": final.new_order_ok / elapsed,
                "avg_latency_ms": avg_ms(final.new_order_ns, final.new_order_ok),
            },
            "payment": {
                "ok": final.payment_ok,
                "err": final.payment_err,
                "ops_per_sec": final.payment_ok / elapsed,
                "avg_latency_ms": avg_ms(final.payment_ns, final.payment_ok),
            },
            "stock": {
                "ok": final.stock_ok,
                "err": final.stock_err,
                "ops_per_sec": final.stock_ok / elapsed,
                "avg_latency_ms": avg_ms(final.stock_ns, final.stock_ok),
            },
            "total_ok": final.new_order_ok + final.payment_ok + final.stock_ok,
            "total_err": final.new_order_err + final.payment_err + final.stock_err,
            "total_ops_per_sec":
                (final.new_order_ok + final.payment_ok + final.stock_ok) / elapsed,
        },
        "errors_sample": final.last_error,
    }
    return summary


# ─── CLI ───────────────────────────────────────────────────────────────────


def parse_mix(s: str) -> tuple:
    parts = [int(x) for x in s.split(",")]
    if len(parts) != 3:
        raise argparse.ArgumentTypeError("--mix expects three comma-separated ints (NewOrder,Payment,Stock)")
    if sum(parts) <= 0:
        raise argparse.ArgumentTypeError("--mix percentages must sum > 0")
    return tuple(parts)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--addr", default="http://127.0.0.1:8000",
                   help="server URL incl. scheme (default %(default)s)")
    p.add_argument("--user", default="admin")
    p.add_argument("--password", default="password")
    p.add_argument("--database", default="httpbench")
    p.add_argument("--clients", type=int, default=4)
    p.add_argument("--duration", type=float, default=60.0,
                   help="benchmark duration in seconds (default %(default)s)")
    p.add_argument("--api-version", default="v1")
    p.add_argument("--warehouses", type=int, default=1)
    p.add_argument("--items-per-warehouse", type=int, default=200)
    p.add_argument("--customers-per-warehouse", type=int, default=50)
    p.add_argument("--mix", type=parse_mix, default=(50, 30, 20),
                   help='transaction mix as "NewOrder,Payment,Stock" %% (default 50,30,20)')
    p.add_argument("--reset", action="store_true",
                   help="drop the database before loading")
    p.add_argument("--no-load", action="store_true",
                   help="skip schema + data load (assumes DB already populated)")
    p.add_argument("--load-only", action="store_true",
                   help="setup+seed and exit (no benchmark)")
    p.add_argument("--seed", type=int, default=0,
                   help="rng seed (0 = nondeterministic)")
    p.add_argument("--out", default=None,
                   help="write the JSON summary to this path (default: stdout-only)")
    p.add_argument("--label", default=None,
                   help="label string included in the summary (e.g. 'master' or 'cluster')")
    args = p.parse_args()

    cfg = Config(
        addr=args.addr,
        user=args.user,
        password=args.password,
        database=args.database,
        clients=args.clients,
        duration=args.duration,
        api_version=args.api_version,
        warehouses=args.warehouses,
        items_per_warehouse=args.items_per_warehouse,
        customers_per_warehouse=args.customers_per_warehouse,
        mix=args.mix,
        seed=args.seed,
    )

    # Initial admin client
    admin = TypeDB(cfg)
    print(f"[init] signing in to {cfg.addr} as {cfg.user}")
    admin.signin()

    if args.reset:
        print(f"[init] dropping database {cfg.database!r} (if exists)")
        admin.db_delete(cfg.database)

    if not args.no_load:
        if admin.db_exists(cfg.database):
            print(f"[init] database {cfg.database!r} already exists — using it")
        else:
            print(f"[init] creating database {cfg.database!r}")
            admin.db_create(cfg.database)
            print("[init] defining schema")
            setup_schema(admin, cfg.database)
            print("[init] seeding data")
            seed_data(admin, cfg)

    if args.load_only:
        print("[done] load only, exiting.")
        return 0

    if not admin.db_exists(cfg.database):
        sys.stderr.write(f"ERROR: database {cfg.database!r} does not exist; pass --reset or remove --no-load\n")
        return 2

    summary = run_benchmark(cfg)
    if args.label:
        summary["label"] = args.label

    print()
    print("=" * 60)
    print(f"label                : {args.label or '(none)'}")
    print(f"elapsed              : {summary['elapsed_seconds']:.2f} s")
    r = summary["results"]
    print(f"NewOrder ok / err    : {r['new_order']['ok']} / {r['new_order']['err']}"
          f"   ({r['new_order']['ops_per_sec']:.1f} ops/s, avg {r['new_order']['avg_latency_ms']:.2f} ms)")
    print(f"Payment  ok / err    : {r['payment']['ok']} / {r['payment']['err']}"
          f"   ({r['payment']['ops_per_sec']:.1f} ops/s, avg {r['payment']['avg_latency_ms']:.2f} ms)")
    print(f"Stock    ok / err    : {r['stock']['ok']} / {r['stock']['err']}"
          f"   ({r['stock']['ops_per_sec']:.1f} ops/s, avg {r['stock']['avg_latency_ms']:.2f} ms)")
    print(f"TOTAL    ok / err    : {r['total_ok']} / {r['total_err']}"
          f"   ({r['total_ops_per_sec']:.1f} ops/s)")
    if summary["errors_sample"]:
        print(f"Last error per op    : {summary['errors_sample']}")
    print("=" * 60)

    if args.out:
        with open(args.out, "w") as f:
            json.dump(summary, f, indent=2)
        print(f"[done] wrote summary to {args.out}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
