#!/usr/bin/env python3
"""OCaml startup/memory benchmark runner and plotter.

Usage:
  python3 bench.py measure [N]         -- run all variants N times, append to results.json
  python3 bench.py plot [results.json] -- plot saved results
"""

import os
import subprocess
import sys
import json
import math
from pathlib import Path

RESULTS_FILE = Path("results.json")
DEFAULT_N = 30

VARIANTS = {
    "includeos.tcg":          "apps.x86_64-linux.includeos.program",
    "includeos.kvm":          "apps.x86_64-linux.includeos.kvm.program",
    "linux.tcg":              "apps.x86_64-linux.linux.program",
    "linux.kvm":              "apps.x86_64-linux.linux.kvm.program",
    "linux.unpatched.tcg":    "apps.x86_64-linux.linux.unpatched.program",
    "linux.unpatched.kvm":    "apps.x86_64-linux.linux.unpatched.kvm.program",
}

COLORS = {
    "includeos.tcg":          "tab:green",
    "includeos.kvm":          "tab:green",
    "linux.tcg":              "tab:brown",
    "linux.kvm":              "tab:brown",
    "linux.unpatched.tcg":    "tab:orange",
    "linux.unpatched.kvm":    "tab:orange",
}

GROUPS = {
    "KVM": ["includeos.kvm", "linux.kvm", "linux.unpatched.kvm"],
    "TCG (no KVM)": ["includeos.tcg", "linux.tcg", "linux.unpatched.tcg"],
}

TIMING_FIELDS = [
    "caml_startup_cycles",
    "ocaml_entry_cycles",
]

FIELD_LABELS = {
    "caml_startup_cycles": "OCaml runtime init",
    "ocaml_entry_cycles":  "ocaml_entry scheduler code",
}

# All fields to print in the stats table.
ALL_FIELDS = TIMING_FIELDS + [
    "peak_requested_bytes",
    "peak_rss_kb",
    "count_alloc",
    "count_alloc_at",
]


def parse_output(text: str) -> dict[str, float]:
    """Extract fields from text between [ocaml start] and [ocaml end]."""
    in_section = False
    data = {}
    for line in text.splitlines():
        if "[ocaml start]" in line:
            in_section = True
            continue
        if "[ocaml end]" in line:
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
    only = os.environ.get("BENCH_VARIANTS")
    for variant in (only.split(",") if only else VARIANTS):
        measure_variant(variant, n, results)
        save_results(results)
    print(f"saved to {RESULTS_FILE}")


def print_stats(results: dict):
    variants = list(results.keys())
    fields = [f for f in ALL_FIELDS
              if any(f in r for runs in results.values() for r in runs)]

    col_f = max(len(f) for f in fields)
    col_v = max(len(v) for v in variants)
    header = (f"{'field':<{col_f}}  {'variant':<{col_v}}  "
              f"{'n':>4}  {'mean':>12}  {'stddev':>10}  {'cv':>6}  "
              f"{'min':>12}  {'max':>12}")
    print(header)
    print("-" * len(header))

    for field in fields:
        first = True
        for variant in variants:
            values = [r[field] for r in results[variant] if field in r]
            if not values:
                continue
            n = len(values)
            mean = sum(values) / n
            std = math.sqrt(sum((v - mean) ** 2 for v in values) / max(n - 1, 1))
            cv = 100 * std / mean if mean else 0.0
            label = field if first else ""
            print(f"{label:<{col_f}}  {variant:<{col_v}}  {n:>4}  "
                  f"{mean:>12.1f}  {std:>10.1f}  {cv:>5.1f}%  "
                  f"{min(values):>12.1f}  {max(values):>12.1f}")
            first = False
        print()


def plot(results_file: Path = RESULTS_FILE):
    try:
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        print("matplotlib and numpy required: pip install matplotlib numpy")
        sys.exit(1)

    results = json.loads(results_file.read_text())
    print_stats(results)

    fields = [f for f in TIMING_FIELDS
              if any(f in r for runs in results.values() for r in runs)]

    kvm_variants = [v for v in GROUPS.get("KVM", []) if v in results and results[v]]

    # One subplot per timing field, KVM only (TCG cycles are emulated, not comparable).
    n_fields = len(fields)
    fig, axes = plt.subplots(1, n_fields, figsize=(4 * n_fields, 5))
    if n_fields == 1:
        axes = [axes]

    x = np.arange(len(kvm_variants))
    width = 0.5

    for ax, field in zip(axes, fields):
        for i, variant in enumerate(kvm_variants):
            runs = results[variant]
            values = [r[field] for r in runs if field in r]
            if not values:
                continue
            mean = sum(values) / len(values)
            std = math.sqrt(sum((v - mean) ** 2 for v in values) / max(len(values) - 1, 1))
            if "includeos" in variant:
                label = "IncludeOS"
            elif "unpatched" in variant:
                label = "Linux (stock)"
            else:
                label = "Linux (matched)"
            ax.bar(i, mean, width, label=label, yerr=std,
                   color=COLORS.get(variant),
                   capsize=4, error_kw={"elinewidth": 1})

        def variant_label(v):
            if "includeos" in v: return "IncludeOS"
            if "unpatched" in v: return "Linux (stock)"
            return "Linux (matched)"

        ax.set_title(FIELD_LABELS.get(field, field.replace("_", " ")))
        ax.set_xticks(x)
        ax.set_xticklabels([variant_label(v) for v in kvm_variants])
        ax.yaxis.set_major_formatter(
            plt.FuncFormatter(lambda v, _: f"{v/1e6:.1f}M" if v >= 1e6 else f"{v/1e3:.0f}K")
        )
        ax.set_ylabel("RDTSC cycles")
        ax.legend()
        ax.grid(True, axis="y", alpha=0.3)
        ax.set_ylim(bottom=0)

    fig.suptitle("OCaml 5.3 startup and entry under QEMU/KVM — IncludeOS vs Linux")

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
