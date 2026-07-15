#!/usr/bin/env python3
"""Measure compiled Keybay run overhead against the same child directly."""

from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import time


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, int(len(ordered) * fraction))
    return ordered[index]


def elapsed_ms(command: list[str]) -> float:
    started = time.perf_counter_ns()
    result = subprocess.run(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        check=False,
    )
    elapsed = (time.perf_counter_ns() - started) / 1_000_000
    if result.returncode != 0:
        raise RuntimeError(
            f"command failed ({result.returncode}): {command!r}: {result.stderr!r}"
        )
    return elapsed


def main() -> int:
    if len(sys.argv) != 5:
        print(
            f"usage: {sys.argv[0]} HARNESS APP_ID MANIFEST ITERATIONS",
            file=sys.stderr,
        )
        return 2
    harness, app_id, manifest, raw_iterations = sys.argv[1:]
    iterations = int(raw_iterations)
    child = ["/usr/bin/true"]
    keybay = [harness, app_id, "run", "-f", manifest, "--", *child]

    elapsed_ms(keybay)
    baseline = [elapsed_ms(child) for _ in range(iterations)]
    samples = [elapsed_ms(keybay) for _ in range(iterations)]
    baseline_median = statistics.median(baseline)
    overhead = [max(0.0, sample - baseline_median) for sample in samples]
    result = {
        "platform": sys.platform,
        "machine": os.uname().machine,
        "iterations": iterations,
        "baseline_p50_ms": round(statistics.median(baseline), 3),
        "run_p50_ms": round(statistics.median(samples), 3),
        "run_p95_ms": round(percentile(samples, 0.95), 3),
        "overhead_p50_ms": round(statistics.median(overhead), 3),
        "overhead_p95_ms": round(percentile(overhead, 0.95), 3),
    }
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
