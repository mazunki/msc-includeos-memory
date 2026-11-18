#!/usr/bin/env python3
"""Boot one binary N times and collect its timings.

Usage:
  ./bench.py measure [N] <cmd...>  -- run <cmd...> N times, append to results.json
  ./bench.py plot [results.json]   -- plot saved results

BENCH_RESULTS sets the results file. A boot that exceeds
BENCH_TIMEOUT_SECONDS (120) is killed and retried, up to BENCH_MAX_RETRIES (3).
"""

import os
import signal
import subprocess
import sys
import json
import math
from datetime import datetime, timezone
from pathlib import Path

RESULTS_FILE = Path(os.environ.get("BENCH_RESULTS", "results.json"))
TIMEOUT_LOG_FILE = Path(os.environ.get("BENCH_TIMEOUT_LOG", RESULTS_FILE.parent / "bench-timeouts.log"))
TIMEOUT_SECONDS = float(os.environ.get("BENCH_TIMEOUT_SECONDS", "120"))
MAX_RETRIES = int(os.environ.get("BENCH_MAX_RETRIES", "3"))
DEFAULT_N = 30


def parse_output(text: str) -> dict[str, float]:
    """Extract 'label value' lines found between [service start]/[service end]."""
    in_section = False
    data = {}
    for line in text.splitlines():
        if "[service start]" in line:
            in_section = True
            continue
        if "[service end]" in line:
            break
        if not in_section:
            continue
        parts = line.split()
        if len(parts) == 2:
            try:
                data[parts[0]] = float(parts[1])
            except ValueError:
                pass
    return data


def log_timeout(argv: list[str]):
    ts = datetime.now(timezone.utc).isoformat(timespec="seconds")
    line = f"{ts}  timed out after {TIMEOUT_SECONDS:.0f}s: {' '.join(argv)}\n"
    with open(TIMEOUT_LOG_FILE, "a") as f:
        f.write(line)
    print(f"\nwarning: {line.strip()}", file=sys.stderr)


def run_once(argv: list[str]) -> dict[str, float]:
    # Own process group, so a timeout also kills qemu.
    proc = subprocess.Popen(
        argv, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    try:
        stdout, _ = proc.communicate(timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()
        log_timeout(argv)
        return {}

    data = parse_output(stdout)
    if not data:
        print(f"\nwarning: no output parsed from run (exit {proc.returncode})", file=sys.stderr)
        if stdout:
            print(stdout[-1000:], file=sys.stderr)
    return data


def load_results() -> list:
    if RESULTS_FILE.exists():
        return json.loads(RESULTS_FILE.read_text())
    return []


def save_results(results: list):
    RESULTS_FILE.write_text(json.dumps(results, indent=2))


def measure(n: int, argv: list[str]):
    results = load_results()
    print(f"measuring ({n} runs)", file=sys.stderr)
    runs = []
    i = 0
    retries = 0
    while i < n:
        print(f"\r  run {i+1}/{n}...", end="", flush=True, file=sys.stderr)
        data = run_once(argv)
        if data:
            runs.append(data)
            save_results(results + runs)
            i += 1
            retries = 0
        else:
            retries += 1
            if retries >= MAX_RETRIES:
                print(f"\nwarning: giving up on run {i+1}/{n} after {MAX_RETRIES} failed attempts", file=sys.stderr)
                i += 1
                retries = 0
    print(f"\r  {len(runs)}/{n} runs parsed.  ", file=sys.stderr)
    results.extend(runs)
    save_results(results)
    print(f"saved {len(results)} total runs to {RESULTS_FILE}")


# One scalar per boot. fill/interleaved_fill are handled by analyze.py.
FAMILIES: dict[str, tuple[str, str]] = {
    "alloc": ("batched", "allocation size (bytes)"),
    "free": ("batched", "allocation size (bytes)"),
    "alloc_interleaved": ("interleaved", "allocation size (bytes)"),
    "free_interleaved": ("interleaved", "allocation size (bytes)"),
    "count-apply": ("jq_count", "element count (n)"),
    "count-alloc": ("jq_count", "element count (n)"),
    "count-reset": ("jq_count", "element count (n)"),
    "size-apply": ("jq_size", "string length (bytes)"),
    "size-byte": ("jq_size", "string length (bytes)"),
    "size-reset": ("jq_size", "string length (bytes)"),
}


def parse_label(label: str) -> tuple[str, str, int] | None:
    """"posix.alloc.1024" -> ("posix", "alloc", 1024); None for other labels."""
    parts = label.split(".")
    if len(parts) != 3:
        return None
    allocator, op, size = parts
    if not size.isdigit():
        return None
    return allocator, op, int(size)


def valid_values(results: list, label: str) -> tuple[list[float], int]:
    """(values, n_excluded); negative values are error sentinels from the benchmark and are skipped."""
    raw = [r[label] for r in results if label in r]
    values = [v for v in raw if v >= 0]
    return values, len(raw) - len(values)


def print_stats(results: list, labels: list[str]):
    families: dict[str, list[str]] = {}
    skipped_unfamiliar = 0
    skipped_all_invalid = []
    for label in labels:
        parsed = parse_label(label)
        if parsed is None:
            continue
        family_key = FAMILIES.get(parsed[1])
        if family_key is None:
            skipped_unfamiliar += 1
            continue
        families.setdefault(family_key[0], []).append(label)

    for family, family_labels in families.items():
        print(f"=== {family} ===")
        col = max(len(l) for l in family_labels)
        header = f"{'label':<{col}}  {'n':>4}  {'excl':>4}  {'mean':>9}  {'stddev':>8}  {'cv':>6}  {'min':>9}  {'max':>9}"
        print(header)
        print("-" * len(header))
        for label in sorted(family_labels):
            values, n_excluded = valid_values(results, label)
            if not values:
                skipped_all_invalid.append(label)
                continue
            n = len(values)
            mean = sum(values) / n
            std = math.sqrt(sum((v - mean) ** 2 for v in values) / max(n - 1, 1))
            cv = 100 * std / mean if mean else 0.0
            print(f"{label:<{col}}  {n:>4}  {n_excluded:>4}  {mean:>9.3f}  {std:>8.3f}  {cv:>5.1f}%  {min(values):>9.3f}  {max(values):>9.3f}")
        print()

    if skipped_unfamiliar:
        print(f"({skipped_unfamiliar} fill/interleaved_fill summary labels omitted -- see analyze.py)")
    if skipped_all_invalid:
        print(f"({len(skipped_all_invalid)} labels omitted, every run returned the error sentinel: {', '.join(skipped_all_invalid)})")


def sorted_labels(results: list) -> list[str]:
    seen = {l for r in results for l in r}
    return sorted(seen)


def plot(results_file: Path = RESULTS_FILE):
    try:
        import matplotlib.pyplot as plt
    except ImportError:
        print("matplotlib required for plotting: pip install matplotlib")
        sys.exit(1)

    results = json.loads(results_file.read_text())
    labels = sorted_labels(results)
    print_stats(results, labels)

    # (family, xlabel) -> {op: {allocator: [(size, mean, std), ...]}}
    by_family: dict[tuple[str, str], dict[str, dict[str, list]]] = {}
    for label in labels:
        parsed = parse_label(label)
        if parsed is None:
            continue
        allocator, op, size = parsed
        family_key = FAMILIES.get(op)
        if family_key is None:
            continue
        values, _ = valid_values(results, label)
        if not values:
            continue
        mean = sum(values) / len(values)
        std = math.sqrt(sum((v - mean) ** 2 for v in values) / max(len(values) - 1, 1))
        by_family.setdefault(family_key, {}).setdefault(op, {}).setdefault(allocator, []).append((size, mean, std))

    colors = {"posix": "tab:brown", "includeos": "tab:green"}
    for (family, xlabel), ops in by_family.items():
        op_names = sorted(ops)
        fig, axes = plt.subplots(1, len(op_names), figsize=(6 * len(op_names), 5), squeeze=False)
        axes = axes[0]
        for ax, op in zip(axes, op_names):
            for allocator, points in sorted(ops[op].items()):
                points.sort()
                sizes = [p[0] for p in points]
                means = [p[1] for p in points]
                stds = [p[2] for p in points]
                ax.errorbar(sizes, means, yerr=stds, marker="o", label=allocator,
                            color=colors.get(allocator), capsize=4)
            ax.set_xscale("log")
            ax.set_yscale("log")
            ax.set_xlabel(xlabel)
            ax.set_ylabel("RDTSC cycles")
            ax.set_title(op)
            ax.legend()
            ax.grid(True, which="both", alpha=0.3)
        plt.tight_layout()
        out = results_file.with_name(f"{results_file.stem}-{family}.png")
        plt.savefig(out, dpi=150)
        print(f"saved {out}")
    plt.show()


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    cmd = sys.argv[1]

    if cmd == "measure":
        n = DEFAULT_N
        argv = []
        if len(sys.argv) > 2:
            if sys.argv[2].isdigit():
                n = int(sys.argv[2])
                argv = sys.argv[3:]
            else:
                argv = sys.argv[2:]
        if not argv:
            print("measure requires a command to run, e.g. measure 100 boot ./x.elf.bin --kvm")
            sys.exit(1)
        measure(n, argv)

    elif cmd == "plot":
        f = Path(sys.argv[2]) if len(sys.argv) > 2 else RESULTS_FILE
        plot(f)

    else:
        print(f"unknown command '{cmd}'. use measure or plot.")
        sys.exit(1)


if __name__ == "__main__":
    main()
