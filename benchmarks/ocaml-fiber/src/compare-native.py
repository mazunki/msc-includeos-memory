#!/usr/bin/env python3
"""Run the three Linux builds natively, pinned to core 2, N=30 times each."""
import statistics
import subprocess

VARIANTS = {"stock": "linux-unpatched", "trimmed": "linux-nomapstack", "matched": "linux"}
FIELDS = ["caml_startup_cycles", "ocaml_entry_cycles", "peak_requested_bytes", "count_alloc"]
N = 30

for name, pkg in VARIANTS.items():
    out = subprocess.run(["nix", "build", "--no-link", "--print-out-paths", f".#{pkg}"],
                         capture_output=True, text=True, check=True).stdout.strip()
    data = {f: [] for f in FIELDS}
    for _ in range(N):
        text = subprocess.run(["taskset", "-c", "2", f"{out}/bin/hello_linux"],
                              capture_output=True, text=True, timeout=30).stdout
        for line in text.splitlines():
            parts = line.split()
            if len(parts) == 2 and parts[0] in FIELDS:
                data[parts[0]].append(float(parts[1]))
    print(f"{name}:")
    for f in FIELDS:
        v = data[f]
        if v:
            mean, std, med = statistics.mean(v), statistics.pstdev(v), statistics.median(v)
            print(f"  {f}: mean={mean:,.0f} median={med:,.0f} std={std:,.0f} "
                  f"({100 * std / mean if mean else 0:.1f}%) n={len(v)}")
