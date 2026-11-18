#!/usr/bin/env python3
"""sandmark benchmark runner and plotter for IncludeOS vs Linux comparison

Usage:
  python3 bench.py validate [BENCHMARKS...]       -- check each variant builds, runs, and agrees
  python3 bench.py measure  [BENCHMARKS...] [N]   -- run benchmarks N times each
  python3 bench.py plot   [results.json]          -- plot saved results
  python3 bench.py stats  [results.json]          -- print stats table
  python3 bench.py list                           -- list available benchmark names

BENCHMARKS is an optional space-separated list; defaults to all known benchmarks.
N defaults to 30.
"""

import subprocess
import sys
import json
import math
import os
import signal
from pathlib import Path

RESULTS_FILE = Path("results.json")
DEFAULT_N = 30

# all known benchmark names (must match keys in flake.nix benchmarks attrset)
ALL_BENCHMARKS = [
    # algorithmic
    "almabench", "bdd", "hamming", "soli", "kb", "kb_no_exc", "sequence_cps",
    # numerical
    "dka", "crout", "qr",
    # sequential recursion benchmarks (rec_eff_* use pre-OCaml-5 syntax, excluded)
    "rec_seq_fib", "rec_seq_tak", "rec_seq_ack", "rec_seq_motzkin", "rec_seq_sudan",
    # allocation / data-structure microbenchmarks
    "alloc", "morestacks", "lazy_primes",
]

# {bm} is replaced with the benchmark name.
ALL_VARIANTS = {
    "linux.kvm":           "apps.x86_64-linux.{bm}.kvm.program",
    "linux.unpatched.kvm": "apps.x86_64-linux.{bm}.unpatched.kvm.program",
    "includeos.kvm":       "apps.x86_64-linux.{bm}.includeos.kvm.program",
    # built without ocamlopt -g
    "linux.nog.kvm":       "apps.x86_64-linux.{bm}.nog.kvm.program",
    "includeos.nog.kvm":   "apps.x86_64-linux.{bm}.nog.includeos.kvm.program",
    # booted with -cpu host instead of kvm64
    "linux.cpuhost.kvm":     "apps.x86_64-linux.{bm}.cpuhost.kvm.program",
    "includeos.cpuhost.kvm": "apps.x86_64-linux.{bm}.cpuhost.includeos.kvm.program",
}
# argv sets from flake.nix `argvSets` (only built for benchmarks listed in the set)
for _set in ["sm"]:
    ALL_VARIANTS[f"linux.{_set}.kvm"]     = f"apps.x86_64-linux.{{bm}}.{_set}.kvm.program"
    ALL_VARIANTS[f"includeos.{_set}.kvm"] = f"apps.x86_64-linux.{{bm}}.{_set}.includeos.kvm.program"

# Variants that validate/measure run. Override with a comma-separated list, e.g.
#   BENCH_VARIANTS=linux.kvm,includeos.kvm,linux.nog.kvm,includeos.nog.kvm
DEFAULT_VARIANTS = ["linux.kvm", "linux.unpatched.kvm", "includeos.kvm"]
_selected = os.environ.get("BENCH_VARIANTS")
_selected = _selected.split(",") if _selected else DEFAULT_VARIANTS
_unknown = [v for v in _selected if v not in ALL_VARIANTS]
if _unknown:
    sys.exit(f"unknown variant(s) in BENCH_VARIANTS: {', '.join(_unknown)}")
VARIANTS = {v: ALL_VARIANTS[v] for v in _selected}

COLORS = {
    "linux.kvm":           "tab:brown",
    "linux.unpatched.kvm": "tab:orange",
    "includeos.kvm":       "tab:green",
    "linux.nog.kvm":       "tab:red",
    "includeos.nog.kvm":   "tab:olive",
}

TIMING_FIELDS = ["caml_startup_cycles", "ocaml_entry_cycles"]

ALL_FIELDS = TIMING_FIELDS + [
    "peak_requested_bytes",
    "peak_rss_kb",
    "count_alloc",
    "count_alloc_at",
]


def parse_output(text: str) -> dict[str, float]:
    """Extract key-value pairs from between [ocaml start] and [ocaml end]."""
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


def parse_benchmark_output(text: str) -> str:
    """Extract the benchmark's own stdout (lines between [bench start] and [bench end])."""
    in_section = False
    lines = []
    for line in text.splitlines():
        if "[bench start]" in line:
            in_section = True
            continue
        if "[bench end]" in line:
            break
        if in_section:
            lines.append(line)
    return "\n".join(lines).strip()


def resolve_program(variant: str, attr: str, verbose: bool = True) -> str | None:
    """Evaluate the nix app attr and return the program path, building if needed."""
    result = subprocess.run(
        ["nix", "eval", "--raw", f".#{attr}"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        if verbose:
            print(f"  skip: failed to resolve .#{attr}", file=sys.stderr)
        return None
    program = result.stdout.strip()
    if not Path(program).exists():
        if verbose:
            print(f"  building {variant}...", flush=True, file=sys.stderr)
        app_fragment = attr.removeprefix("apps.x86_64-linux.").removesuffix(".program")
        subprocess.run(
            ["nix", "run", f".#{app_fragment}"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    if not Path(program).exists():
        if verbose:
            print(f"  skip: build failed for {attr}", file=sys.stderr)
        return None
    return program


RUN_TIMEOUT = 120  # seconds


# BENCH_PERF=stat|kvm|proc wraps each boot; output goes to perf/.
PERF_MODE = os.environ.get("BENCH_PERF", "")
PERF_DIR = Path("perf")
PERF_EVENTS = os.environ.get("BENCH_PERF_EVENTS") or ",".join([
    "cycles:G", "instructions:G", "branch-misses:G", "cache-misses:G", "cycles:H",
    "page-faults", "context-switches", "cpu-migrations",
])
if PERF_MODE not in ("", "stat", "kvm", "proc"):
    sys.exit(f"BENCH_PERF must be 'stat', 'kvm' or 'proc', not '{PERF_MODE}'")


def perf_out(tag: str) -> Path:
    PERF_DIR.mkdir(exist_ok=True)
    out = PERF_DIR / f"{tag}.{PERF_MODE}"
    n = 0
    while out.exists():
        n += 1
        out = PERF_DIR / f"{tag}.{n}.{PERF_MODE}"
    return out


def _qemu_threads(session: int) -> dict[int, dict]:
    """Per-thread times of QEMU processes in the given session, from /proc."""
    tick = os.sysconf("SC_CLK_TCK")
    found = {}
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            stat = Path(f"/proc/{pid}/stat").read_text()
            comm = stat[stat.index("(") + 1:stat.rindex(")")]
            if int(stat[stat.rindex(")") + 2:].split()[3]) != session or "qemu-system" not in comm:
                continue
            for tid in os.listdir(f"/proc/{pid}/task"):
                t = Path(f"/proc/{pid}/task/{tid}/stat").read_text()
                f = t[t.rindex(")") + 2:].split()
                status = Path(f"/proc/{pid}/task/{tid}/status").read_text()
                cs = dict(l.split(":\t") for l in status.splitlines() if "ctxt_switches" in l)
                utime, stime, guest = int(f[11]) / tick, int(f[12]) / tick, int(f[40]) / tick
                found[int(tid)] = {
                    "name": t[t.index("(") + 1:t.rindex(")")],
                    "guest_s": guest, "host_user_s": utime - guest, "host_kernel_s": stime,
                    "voluntary_switches": int(cs.get("voluntary_ctxt_switches", 0)),
                    "involuntary_switches": int(cs.get("nonvoluntary_ctxt_switches", 0)),
                }
        except (OSError, ValueError, IndexError):
            continue
    return found


class ProcSampler:
    """Polls QEMU's threads while a boot runs; keeps the last reading per thread."""
    def __init__(self, session: int, out: Path):
        import threading
        self.session, self.out, self.last = session, out, {}
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while not self.stop.wait(0.05):
            self.last.update(_qemu_threads(self.session))

    def finish(self):
        self.stop.set()
        self.thread.join()
        total = {k: round(sum(t[k] for t in self.last.values()), 3)
                 for k in ("guest_s", "host_user_s", "host_kernel_s",
                           "voluntary_switches", "involuntary_switches")}
        self.out.write_text(json.dumps({"total": total, "threads": self.last}, indent=1))


def perf_wrap(program: str, tag: str | None) -> list[str]:
    if PERF_MODE in ("", "proc") or tag is None:
        return [program]
    out = perf_out(tag)
    if PERF_MODE == "stat":
        return ["perf", "stat", "-x", ",", "-o", str(out), "-e", PERF_EVENTS, "--", program]
    return ["perf", "kvm", "stat", "record", "-q", "-o", str(out), "--", program]


def run_program(program: str, tag: str | None = None) -> tuple[str, bool]:
    """Run program, returning (stdout, timed_out). A timeout kills the whole process group."""
    proc = subprocess.Popen(
        perf_wrap(program, tag), text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    sampler = ProcSampler(proc.pid, perf_out(tag)) if PERF_MODE == "proc" and tag else None
    try:
        stdout, _ = proc.communicate(timeout=RUN_TIMEOUT)
        if sampler:
            sampler.finish()
        return stdout, False
    except subprocess.TimeoutExpired:
        if sampler:
            sampler.finish()
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.communicate()
        return "", True


def run_once(program: str, tag: str | None = None) -> dict[str, float]:
    stdout, timed_out = run_program(program, tag)
    if timed_out:
        print(f"\n  timeout after {RUN_TIMEOUT}s — skipping run", file=sys.stderr)
        return {}
    data = parse_output(stdout)
    if not data:
        print(f"\n  warning: no output parsed", file=sys.stderr)
        if stdout:
            print(stdout[-300:], file=sys.stderr)
    return data


def load_results() -> dict:
    if RESULTS_FILE.exists():
        return json.loads(RESULTS_FILE.read_text())
    return {}


def save_results(results: dict):
    RESULTS_FILE.write_text(json.dumps(results, indent=2))


VALIDATE_DIR = Path("validate_output")

def validate(benchmark_names: list[str]) -> bool:
    """Run each benchmark once per variant and check the outputs agree; saves them to validate_output/."""
    VALIDATE_DIR.mkdir(exist_ok=True)
    all_ok = True
    for bm in benchmark_names:
        print(f"\n[{bm}]")
        output_files: dict[str, Path] = {}
        outputs: dict[str, str] = {}
        for variant, attr_tmpl in VARIANTS.items():
            attr = attr_tmpl.format(bm=bm)
            program = resolve_program(variant, attr)
            if program is None:
                print(f"  {variant}: SKIP (build failed)")
                all_ok = False
                continue
            stdout, timed_out = run_program(program, f"{bm}.{variant}.validate")
            out_path = VALIDATE_DIR / f"{bm}.{variant.replace('/', '_')}.txt"
            out_path.write_text(stdout)
            if timed_out:
                print(f"  {variant}: TIMEOUT (>{RUN_TIMEOUT}s) -> {out_path}")
                all_ok = False
                continue
            timing = parse_output(stdout)
            bench_out = parse_benchmark_output(stdout)
            if not timing:
                print(f"  {variant}: FAIL (no timing output) -> {out_path}")
                all_ok = False
                continue
            cycles = timing.get("caml_startup_cycles", 0)
            n_lines = bench_out.count("\n") + 1 if bench_out else 0
            print(f"  {variant}: ok  ({cycles/1e6:.0f}M cycles, {n_lines} lines) -> {out_path}")
            output_files[variant] = out_path
            outputs[variant] = bench_out

        if len(outputs) > 1:
            unique = set(outputs.values())
            if len(unique) > 1:
                print(f"  OUTPUT MISMATCH — diff the files above to inspect")
                all_ok = False
            else:
                print(f"  output consistent across {len(outputs)} variant(s)")

    print()
    if all_ok:
        print("All benchmarks passed validation.")
    else:
        print("Some benchmarks failed — see above.", file=sys.stderr)
    return all_ok


def measure(benchmark_names: list[str], n: int):
    results = load_results()
    for bm in benchmark_names:
        results.setdefault(bm, {})
        for variant, attr_tmpl in VARIANTS.items():
            attr = attr_tmpl.format(bm=bm)
            print(f"[{bm}] resolving '{variant}'...", end=" ", flush=True, file=sys.stderr)
            program = resolve_program(variant, attr)
            if program is None:
                continue
            print(f"ok", file=sys.stderr)
            print(f"[{bm}] measuring '{variant}' ({n} runs)", file=sys.stderr)
            runs = []
            for i in range(n):
                print(f"\r  run {i+1}/{n}...", end="", flush=True, file=sys.stderr)
                data = run_once(program, f"{bm}.{variant}.{i+1}")
                if data:
                    runs.append(data)
            print(f"\r  {len(runs)}/{n} runs parsed.  ", file=sys.stderr)
            results[bm].setdefault(variant, [])
            results[bm][variant].extend(runs)
            save_results(results)
    print(f"saved to {RESULTS_FILE}")


def _stats_for(values: list[float]) -> tuple[int, float, float, float, float, float]:
    n = len(values)
    if n == 0:
        return 0, 0, 0, 0, 0, 0
    mean = sum(values) / n
    std = math.sqrt(sum((v - mean) ** 2 for v in values) / max(n - 1, 1))
    cv = 100 * std / mean if mean else 0.0
    return n, mean, std, cv, min(values), max(values)


def print_stats(results: dict):
    benchmarks = list(results.keys())
    variants   = [v for v in ALL_VARIANTS if any(v in results[bm] for bm in benchmarks)]
    fields = [f for f in ALL_FIELDS
              if any(f in r
                     for bm in benchmarks
                     for v in results[bm].values()
                     for r in v)]
    if not fields:
        print("no data yet")
        return

    col_bm = max(len(b) for b in benchmarks)
    col_f  = max(len(f) for f in fields)
    col_v  = max(len(v) for v in variants)
    header = (f"{'benchmark':<{col_bm}}  {'field':<{col_f}}  {'variant':<{col_v}}  "
              f"{'n':>4}  {'mean':>12}  {'stddev':>10}  {'cv':>6}  "
              f"{'min':>12}  {'max':>12}")
    print(header)
    print("-" * len(header))

    for bm in benchmarks:
        for field in fields:
            first_field = True
            for variant in variants:
                runs = results[bm].get(variant, [])
                values = [r[field] for r in runs if field in r]
                n, mean, std, cv, lo, hi = _stats_for(values)
                if n == 0:
                    continue
                bm_lbl    = bm    if (first_field and variant == variants[0]) else ""
                field_lbl = field if (first_field) else ""
                print(f"{bm_lbl:<{col_bm}}  {field_lbl:<{col_f}}  {variant:<{col_v}}  "
                      f"{n:>4}  {mean:>12.1f}  {std:>10.1f}  {cv:>5.1f}%  "
                      f"{lo:>12.1f}  {hi:>12.1f}")
                first_field = False
            if not first_field:
                pass  # blank line between fields is handled below
        print()


def _collect_means(results: dict, benchmarks: list[str], variants: list[str]) -> dict[str, tuple[list, list, list]]:
    """Return {variant: (means, stds, ns)} for caml_startup_cycles."""
    out = {}
    for variant in variants:
        means, stds, ns = [], [], []
        for bm in benchmarks:
            values = [r["caml_startup_cycles"]
                      for r in results[bm].get(variant, [])
                      if "caml_startup_cycles" in r]
            n, mean, std, *_ = _stats_for(values)
            means.append(mean)
            stds.append(std)
            ns.append(n)
        out[variant] = (means, stds, ns)
    return out


def plot(results_file: Path = RESULTS_FILE):
    try:
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        print("matplotlib and numpy required: pip install matplotlib numpy")
        sys.exit(1)

    results = json.loads(results_file.read_text())
    print_stats(results)

    benchmarks = [bm for bm in ALL_BENCHMARKS if bm in results]
    if not benchmarks:
        print("no data to plot")
        return

    variants  = [v for v in ALL_VARIANTS if any(v in results[bm] for bm in benchmarks)]
    base      = "linux.kvm"
    target    = "includeos.kvm" if "includeos.kvm" in variants else next(
        (v for v in variants if v != base), base)

    def _ratio_key(bm: str) -> float:
        base_vals   = [r["caml_startup_cycles"] for r in results[bm].get(base, [])   if "caml_startup_cycles" in r]
        target_vals = [r["caml_startup_cycles"] for r in results[bm].get(target, []) if "caml_startup_cycles" in r]
        if not base_vals or not target_vals:
            return -1.0
        return (sum(target_vals) / len(target_vals)) / (sum(base_vals) / len(base_vals))

    benchmarks.sort(key=_ratio_key, reverse=True)

    n_bm      = len(benchmarks)
    n_var     = len(variants)
    data      = _collect_means(results, benchmarks, variants)
    x         = np.arange(n_bm)
    width     = 0.75 / n_var

    all_ns = [n for variant in variants for n in data[variant][2]]
    n_mode = max(set(all_ns), key=all_ns.count) if all_ns else 0
    short_runs = [(bm, variant, n)
                  for variant in variants
                  for bm, n in zip(benchmarks, data[variant][2])
                  if 0 < n < n_mode]

    fig, ax = plt.subplots(figsize=(max(12, n_bm * 0.6), 8))

    subtitle = f"n={n_mode} runs/benchmark/variant"
    if short_runs:
        detail = ", ".join(f"{bm}/{variant}={n}" for bm, variant, n in short_runs)
        subtitle += f"  (fewer completed for: {detail})"
    fig.suptitle(subtitle, fontsize=9, color="dimgray")

    # Grouped bars on a log axis, ratio above each cluster.
    for i, variant in enumerate(variants):
        means, stds, _ = data[variant]
        offset = (i - (n_var - 1) / 2) * width
        ax.bar(x + offset, means, width,
               label=variant, yerr=stds,
               color=COLORS.get(variant),
               capsize=3, error_kw={"elinewidth": 0.8}, zorder=2)

    base_means, base_stds, _ = data[base]
    target_means, target_stds, _ = data[target]
    for xi, mb, sb, mt, st in zip(x, base_means, base_stds, target_means, target_stds):
        if mb > 0 and mt > 0:
            top = max(mb + sb, mt + st)
            ax.annotate(f"{mt / mb:.2f}×", (xi, top),
                        textcoords="offset points", xytext=(0, 4),
                        ha="center", fontsize=7)

    ax.set_yscale("log")
    ax.set_xticks(x)
    ax.set_xticklabels(benchmarks, rotation=45, ha="right", fontsize=8)
    ax.yaxis.set_major_formatter(
        plt.FuncFormatter(lambda v, _: f"{v/1e9:.1f}G" if v >= 1e9
                          else f"{v/1e6:.1f}M" if v >= 1e6
                          else f"{v/1e3:.0f}K"))
    ax.set_ylabel("RDTSC cycles  (startup + benchmark run, log scale)")
    ax.set_title(f"Sandmark: {target} vs {base}, OCaml 5.3 "
                 f"— sorted by overhead, labels show {target}/{base} ratio")
    ax.legend()
    ax.grid(True, axis="y", which="both", alpha=0.3)

    plt.tight_layout(rect=(0, 0, 1, 0.97))
    out = results_file.with_suffix(".png")
    plt.savefig(out, dpi=150)
    print(f"saved {out}")
    plt.show()


def procstats(d: Path):
    """Mean QEMU thread times per (benchmark, variant) from BENCH_PERF=proc files."""
    groups: dict[tuple[str, str], list[dict]] = {}
    for f in sorted(d.glob("*.proc")):
        parts = f.name.removesuffix(".proc").split(".")
        bm = parts[0]
        variant = ".".join(p for p in parts[1:] if not p.isdigit() and p != "validate")
        groups.setdefault((bm, variant), []).append(json.loads(f.read_text())["total"])
    keys = ["guest_s", "host_user_s", "host_kernel_s", "voluntary_switches", "involuntary_switches"]
    print(f"{'benchmark':<14}{'variant':<20}{'n':>3}{'guest s':>10}{'qemu s':>9}{'kernel s':>10}"
          f"{'vol sw':>10}{'invol sw':>10}")
    for (bm, v), runs in groups.items():
        mean = {k: sum(r[k] for r in runs) / len(runs) for k in keys}
        print(f"{bm:<14}{v:<20}{len(runs):>3}{mean['guest_s']:>10.2f}{mean['host_user_s']:>9.2f}"
              f"{mean['host_kernel_s']:>10.2f}{mean['voluntary_switches']:>10.0f}"
              f"{mean['involuntary_switches']:>10.0f}")


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)

    cmd = sys.argv[1]

    if cmd == "list":
        for bm in ALL_BENCHMARKS:
            print(bm)

    elif cmd == "validate":
        args = sys.argv[2:]
        benchmark_names = args if args else ALL_BENCHMARKS
        unknown = [b for b in benchmark_names if b not in ALL_BENCHMARKS]
        if unknown:
            print(f"unknown benchmarks: {unknown}", file=sys.stderr)
            sys.exit(1)
        ok = validate(benchmark_names)
        sys.exit(0 if ok else 1)

    elif cmd == "measure":
        args = sys.argv[2:]
        # Last arg is N if it looks like an integer, else it's a benchmark name
        n = DEFAULT_N
        if args and args[-1].isdigit():
            n = int(args.pop())
        benchmark_names = args if args else ALL_BENCHMARKS
        unknown = [b for b in benchmark_names if b not in ALL_BENCHMARKS]
        if unknown:
            print(f"unknown benchmarks: {unknown}", file=sys.stderr)
            sys.exit(1)
        measure(benchmark_names, n)

    elif cmd == "stats":
        f = Path(sys.argv[2]) if len(sys.argv) > 2 else RESULTS_FILE
        print_stats(json.loads(f.read_text()))

    elif cmd == "plot":
        f = Path(sys.argv[2]) if len(sys.argv) > 2 else RESULTS_FILE
        plot(f)

    elif cmd == "procstats":
        procstats(Path(sys.argv[2]) if len(sys.argv) > 2 else PERF_DIR)

    else:
        print(f"unknown command '{cmd}'. see --help.")
        sys.exit(1)


if __name__ == "__main__":
    main()
