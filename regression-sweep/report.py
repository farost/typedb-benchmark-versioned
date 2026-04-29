#!/usr/bin/env python3
"""Generate a regression sweep report from raw benchmark logs."""

import argparse
import os
import re
import statistics
import sys
from datetime import datetime


ANSI_ESCAPE = re.compile(r'\x1b\[[0-9;]*m')


def strip_ansi(s):
    """Remove ANSI escape codes from a string."""
    return ANSI_ESCAPE.sub('', s)


def extract_tpmc_from_log(log_path):
    """Extract tpmC values from a benchmark log file."""
    values = []
    if not os.path.isfile(log_path):
        return values
    with open(log_path) as f:
        for line in f:
            clean = strip_ansi(line)
            m = re.search(r'Run \d+/\d+: ([0-9]+\.[0-9]+) tpmC', clean)
            if m:
                values.append(float(m.group(1)))
    return values


def compute_stats(values):
    """Compute avg, median, min, max, stddev for a list of values."""
    if not values:
        return {"avg": 0, "median": 0, "min": 0, "max": 0, "stddev": 0, "count": 0}
    return {
        "avg": statistics.mean(values),
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "stddev": statistics.stdev(values) if len(values) > 1 else 0,
        "count": len(values),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--versions", nargs="+", required=True)
    parser.add_argument("--raw-dir", required=True)
    parser.add_argument("--runs-per-version", type=int, required=True)
    parser.add_argument("--benchmark-args", required=True)
    args = parser.parse_args()

    # Collect data per version
    version_data = {}
    for version in args.versions:
        all_values = []
        run_details = []
        for run_num in range(1, args.runs_per_version + 1):
            log_path = os.path.join(args.raw_dir, f"bench_{version}_run{run_num}.log")
            values = extract_tpmc_from_log(log_path)
            run_details.append({"run": run_num, "values": values, "stats": compute_stats(values)})
            all_values.extend(values)
        version_data[version] = {
            "runs": run_details,
            "all_values": all_values,
            "stats": compute_stats(all_values),
        }

    # Generate report
    lines = []
    w = lines.append

    w("=" * 70)
    w("  TypeDB Version Regression Sweep Report")
    w("=" * 70)
    w(f"  Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    w(f"  Benchmark: {args.benchmark_args}")
    w(f"  Runs per version: {args.runs_per_version}")
    w(f"  Versions tested: {', '.join(args.versions)}")
    w("")

    # ── Per-version detailed results ──
    w("=" * 70)
    w("  DETAILED RESULTS")
    w("=" * 70)

    for version in args.versions:
        data = version_data[version]
        w("")
        w(f"  TypeDB {version}")
        w(f"  {'─' * 40}")

        for rd in data["runs"]:
            if not rd["values"]:
                w(f"    Run {rd['run']}: FAILED / NO DATA")
                continue
            vals_str = ", ".join(f"{v:.1f}" for v in rd["values"])
            s = rd["stats"]
            w(f"    Run {rd['run']}: [{vals_str}]")
            w(f"           avg={s['avg']:.1f}  median={s['median']:.1f}  "
              f"min={s['min']:.1f}  max={s['max']:.1f}")

        s = data["stats"]
        if s["count"] > 0:
            w(f"")
            w(f"    OVERALL ({s['count']} iterations across {args.runs_per_version} runs):")
            w(f"      Avg:    {s['avg']:.1f} tpmC")
            w(f"      Median: {s['median']:.1f} tpmC")
            w(f"      Min:    {s['min']:.1f}  Max: {s['max']:.1f}")
            w(f"      StdDev: {s['stddev']:.1f}")
        else:
            w(f"    OVERALL: NO DATA")

    # ── Comparison table ──
    w("")
    w("=" * 70)
    w("  COMPARISON TABLE")
    w("=" * 70)
    w("")

    # Header
    w(f"  {'Version':<12} {'Avg':>10} {'Median':>10} {'Min':>10} {'Max':>10} "
      f"{'StdDev':>10} {'N':>5}")
    w(f"  {'─' * 12} {'─' * 10} {'─' * 10} {'─' * 10} {'─' * 10} {'─' * 10} {'─' * 5}")

    for version in args.versions:
        s = version_data[version]["stats"]
        if s["count"] > 0:
            w(f"  {version:<12} {s['avg']:>10.1f} {s['median']:>10.1f} "
              f"{s['min']:>10.1f} {s['max']:>10.1f} {s['stddev']:>10.1f} {s['count']:>5}")
        else:
            w(f"  {version:<12} {'—':>10} {'—':>10} {'—':>10} {'—':>10} {'—':>10} {'—':>5}")

    # ── Relative performance (vs first version with data) ──
    baseline_version = None
    baseline_avg = None
    baseline_median = None
    for version in args.versions:
        s = version_data[version]["stats"]
        if s["count"] > 0:
            baseline_version = version
            baseline_avg = s["avg"]
            baseline_median = s["median"]
            break

    if baseline_version:
        w("")
        w("=" * 70)
        w(f"  RELATIVE PERFORMANCE (baseline = {baseline_version})")
        w("=" * 70)
        w("")
        w(f"  {'Version':<12} {'Avg':>10} {'vs baseline':>14} {'Median':>10} {'vs baseline':>14}")
        w(f"  {'─' * 12} {'─' * 10} {'─' * 14} {'─' * 10} {'─' * 14}")

        for version in args.versions:
            s = version_data[version]["stats"]
            if s["count"] == 0:
                w(f"  {version:<12} {'—':>10} {'—':>14} {'—':>10} {'—':>14}")
                continue

            avg_pct = ((s["avg"] - baseline_avg) / baseline_avg * 100) if baseline_avg else 0
            med_pct = ((s["median"] - baseline_median) / baseline_median * 100) if baseline_median else 0

            avg_delta = f"{avg_pct:+.1f}%"
            med_delta = f"{med_pct:+.1f}%"

            if version == baseline_version:
                avg_delta = "(baseline)"
                med_delta = "(baseline)"

            w(f"  {version:<12} {s['avg']:>10.1f} {avg_delta:>14} "
              f"{s['median']:>10.1f} {med_delta:>14}")

    # ── Pairwise deltas ──
    completed = [v for v in args.versions if version_data[v]["stats"]["count"] > 0]
    if len(completed) >= 2:
        w("")
        w("=" * 70)
        w("  VERSION-TO-VERSION CHANGES")
        w("=" * 70)
        w("")

        for i in range(len(completed) - 1):
            v_prev = completed[i]
            v_next = completed[i + 1]
            s_prev = version_data[v_prev]["stats"]
            s_next = version_data[v_next]["stats"]

            avg_delta = s_next["avg"] - s_prev["avg"]
            avg_pct = (avg_delta / s_prev["avg"] * 100) if s_prev["avg"] else 0
            med_delta = s_next["median"] - s_prev["median"]
            med_pct = (med_delta / s_prev["median"] * 100) if s_prev["median"] else 0

            direction = "FASTER" if avg_delta > 0 else "SLOWER" if avg_delta < 0 else "SAME"

            w(f"  {v_prev} -> {v_next}:")
            w(f"    Avg:    {avg_delta:+.1f} tpmC ({avg_pct:+.1f}%)  {direction}")
            w(f"    Median: {med_delta:+.1f} tpmC ({med_pct:+.1f}%)")
            w("")

    # ── Footer ──
    w("=" * 70)
    w("")

    report = "\n".join(lines)

    # Write to file
    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w") as f:
        f.write(report)

    # Also print to stdout
    print(report)


if __name__ == "__main__":
    main()
