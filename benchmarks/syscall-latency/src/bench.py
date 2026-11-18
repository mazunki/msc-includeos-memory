#!/usr/bin/env python3
"""Syscall latency benchmark runner and plotter.

Usage:
  python3 bench.py measure [N]         -- run all variants N times, append to results.json
  python3 bench.py plot [results.json] -- plot saved results
"""

import subprocess
import sys
import json
import math
from pathlib import Path
from collections import defaultdict

RESULTS_FILE = Path("results.json")
DEFAULT_N = 30

VARIANTS = {
    "includeos.tcg": "apps.x86_64-linux.includeos.program",
    "includeos.kvm": "apps.x86_64-linux.includeos.kvm.program",
    "linux.tcg":     "apps.x86_64-linux.linux.program",
    "linux.kvm":     "apps.x86_64-linux.linux.kvm.program",
}

COLORS = {
    "includeos.tcg": "tab:green",
    "includeos.kvm": "tab:green",
    "linux.tcg":     "tab:brown",
    "linux.kvm":     "tab:brown",
}

GROUPS = {
    "KVM": ["includeos.kvm", "linux.kvm"],
    "TCG (no KVM)": ["includeos.tcg", "linux.tcg"],
}

BENCHMARK_ORDER = [
    "gettid_syscall",
    "getpid_syscall",
    "getpid_libc",
    "gettimeofday",
    "mmap_syscall(256KiB)",
    "mmap_libc(256KiB)",
    "mmap_syscall(1B)",
    "mmap_libc(1B)",
    "malloc(256KiB)",
    "malloc(0)",
]


def parse_output(text: str) -> dict[str, float]:
    """Extract benchmark values from text between [service start] and [service end]."""
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


def resolve_program(variant_key: str, attr: str) -> str:
    """Evaluate and build the nix app program, returning its store path."""
    result = subprocess.run(
        ["nix", "eval", "--raw", f".#{attr}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        print(f"failed to resolve .#{attr}:\n{result.stderr}", file=sys.stderr)
        sys.exit(1)
    program = result.stdout.strip()
    if not Path(program).exists():
        print("building...", end=" ", flush=True, file=sys.stderr)
        subprocess.run(
            ["nix", "run", f".#{variant_key}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    return program


def run_once(program: str) -> dict[str, float]:
    result = subprocess.run(
        [program], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    data = parse_output(result.stdout)
    if not data:
        print(f"\nwarning: no output parsed from run (exit {result.returncode})", file=sys.stderr)
        if result.stdout:
            print(result.stdout[-500:], file=sys.stderr)
    return data


def load_results() -> dict:
    if RESULTS_FILE.exists():
        return json.loads(RESULTS_FILE.read_text())
    return {}


def save_results(results: dict):
    RESULTS_FILE.write_text(json.dumps(results, indent=2))


def measure_variant(variant: str, n: int, results: dict):
    attr = VARIANTS[variant]
    print(f"resolving '{variant}'...", end=" ", flush=True, file=sys.stderr)
    program = resolve_program(variant, attr)
    print(f"ok ({program})", file=sys.stderr)
    print(f"measuring '{variant}' ({n} runs)", file=sys.stderr)

    runs = []
    for i in range(n):
        print(f"\r  run {i+1}/{n}...", end="", flush=True, file=sys.stderr)
        data = run_once(program)
        if data:
            runs.append(data)
    print(f"\r  {len(runs)}/{n} runs parsed.  ", file=sys.stderr)

    results.setdefault(variant, [])
    results[variant].extend(runs)
    print(f"  {len(results[variant])} total runs for '{variant}'")


def measure(n: int):
    results = load_results()
    for variant in VARIANTS:
        measure_variant(variant, n, results)
        save_results(results)
    print(f"saved to {RESULTS_FILE}")


def print_stats(results: dict, benchmarks: list[str]):
    variants = list(results.keys())
    col_b = max(len(b) for b in benchmarks)
    col_v = max(len(v) for v in variants)
    header = f"{'benchmark':<{col_b}}  {'variant':<{col_v}}  {'n':>4}  {'mean':>9}  {'stddev':>8}  {'cv':>6}  {'min':>9}  {'max':>9}"
    print(header)
    print("-" * len(header))
    for bench in benchmarks:
        first = True
        for variant in variants:
            values = [r[bench] for r in results[variant] if bench in r]
            if not values:
                continue
            n = len(values)
            mean = sum(values) / n
            std = math.sqrt(sum((v - mean) ** 2 for v in values) / max(n - 1, 1))
            cv = 100 * std / mean if mean else 0.0
            label = bench if first else ""
            print(f"{label:<{col_b}}  {variant:<{col_v}}  {n:>4}  {mean:>9.3f}  {std:>8.3f}  {cv:>5.1f}%  {min(values):>9.3f}  {max(values):>9.3f}")
            first = False
        if len(variants) > 1:
            print()


def plot(results_file: Path = RESULTS_FILE):
    try:
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        print("matplotlib and numpy required for plotting: pip install matplotlib numpy")
        sys.exit(1)

    results = json.loads(results_file.read_text())

    # Collect benchmark names in preferred order
    seen = set()
    benchmarks = []
    all_seen = {b for runs in results.values() for run in runs for b in run}
    for b in BENCHMARK_ORDER:
        if b in all_seen:
            benchmarks.append(b)
            seen.add(b)
    for b in sorted(all_seen - seen):
        benchmarks.append(b)

    print_stats(results, benchmarks)

    x = np.arange(len(benchmarks))

    # Only include groups that have at least one variant with data
    active_groups = {
        name: [v for v in variants if v in results and results[v]]
        for name, variants in GROUPS.items()
    }
    active_groups = {k: v for k, v in active_groups.items() if v}

    n_groups = len(active_groups)
    fig, axes = plt.subplots(1, n_groups, figsize=(max(10, len(benchmarks) * 1.4) * n_groups / 2, 6),
                             sharey=True)
    if n_groups == 1:
        axes = [axes]

    for ax, (group_name, group_variants) in zip(axes, active_groups.items()):
        n_variants = len(group_variants)
        width = 0.7 / n_variants

        for i, variant in enumerate(group_variants):
            runs = results[variant]
            means, stds = [], []
            for bench in benchmarks:
                values = [r[bench] for r in runs if bench in r]
                if values:
                    mean = sum(values) / len(values)
                    std = math.sqrt(sum((v - mean) ** 2 for v in values) / max(len(values) - 1, 1))
                else:
                    mean, std = 0.0, 0.0
                means.append(mean)
                stds.append(std)

            label = "IncludeOS" if "includeos" in variant else "Linux"
            offset = (i - n_variants / 2 + 0.5) * width
            ax.bar(x + offset, means, width, label=label, yerr=stds,
                   color=COLORS.get(variant),
                   capsize=4, error_kw={"elinewidth": 1})

        ax.set_title(group_name)
        ax.set_xticks(x)
        ax.set_xticklabels(benchmarks, rotation=30, ha="right")
        ax.set_yscale("log")
        ax.legend()
        ax.grid(True, axis="y", alpha=0.3)
        ax.set_ylim(bottom=1)

    axes[0].set_ylabel("RDTSC cycles")
    fig.suptitle("Syscall latency benchmark")

    plt.tight_layout()
    out = results_file.with_suffix(".png")
    plt.savefig(out, dpi=150)
    print(f"saved {out}")
    plt.show()


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    cmd = sys.argv[1]

    if cmd == "measure":
        n = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_N
        measure(n)

    elif cmd == "plot":
        f = Path(sys.argv[2]) if len(sys.argv) > 2 else RESULTS_FILE
        plot(f)

    else:
        print(f"unknown command '{cmd}'. use measure or plot.")
        sys.exit(1)


if __name__ == "__main__":
    main()
