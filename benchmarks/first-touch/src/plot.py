#!/usr/bin/env python3
"""Thesis figure: allocation, free, first-write and later-write cost by size.

usage: plot.py RESULTS_DIR OUT_BASENAME {mmap,custom} [LARGE_DIR]
RESULTS_DIR holds includeos-original/, includeos-thesis/, linux/ from run.sh.
LARGE_DIR (optional, mmap only) is the 32 MiB..1 GiB sweep with the same layout;
its rows are added to the same curves.
"""
import glob
import sys

import numpy as np
import pandas as pd
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker

RES, OUT, ONLY = sys.argv[1], sys.argv[2], sys.argv[3]
LARGE = sys.argv[4] if len(sys.argv) > 4 else None
TSC_GHZ = 4.691
BUCKETS = 2

SYSTEMS = {  # key: (subdir, custom prefix, mmap prefix, color, label)
    "thesis":   ("includeos-thesis",   "unikernel", "unikernel-native", "#1f77b4", "IncludeOS (this work)"),
    "original": ("includeos-original", "unikernel", "unikernel-native", "#5e3c99", "IncludeOS (original)"),
    "linux":    ("linux",              "linux",     "linux-native",     "#e66100", "Linux"),
}
PATH_STYLE = {"custom": dict(linestyle="-", marker="o"), "mmap": dict(linestyle="--", marker="s")}
PANELS = [
    ("request",     "cycles_per_op", "allocation (cycles)",            True),
    ("free",        "cycles_per_op", "free (cycles)",                  True),
    ("touch",       "gb_per_s",      "first write (GB/s)",             True),
    ("touchsample", "gb_per_s",      "later writes, per pass (GB/s)",  False),
]


def load(subdir, prefix, res=None):
    paths = sorted(glob.glob(f"{res or RES}/{subdir}/{prefix}-[0-9]*-kvm.csv"))
    df = pd.concat([pd.read_csv(p, dtype=str) for p in paths], ignore_index=True)
    df = df[df["seq"] != "seq"].copy()
    for c in ("size", "cycle_count", "repeats"):
        df[c] = df[c].astype(int)
    df["cycles_per_op"] = df["cycle_count"] / df["repeats"]
    df["gb_per_s"] = (df["repeats"] * df["size"]) / df["cycle_count"] * TSC_GHZ
    e = np.floor(np.log2(df["size"])).astype(int)
    base = 2.0 ** e
    sub = np.minimum(((df["size"] - base) * BUCKETS // base).astype(int), BUCKETS - 1)
    df["x"] = base * (1 + (sub + 0.5) / BUCKETS)
    return df, len(paths)


data, runs = {}, {}
for key, (sub, pc, pm, _, _) in SYSTEMS.items():
    for path, prefix in (("custom", pc), ("mmap", pm)):
        if path == ONLY:
            data[key, path], runs[key, path] = load(sub, prefix)
            if LARGE and path == "mmap":
                big, nbig = load(sub, prefix, LARGE)
                data[key, path] = pd.concat([data[key, path], big], ignore_index=True)
                runs[key, path] = min(runs[key, path], nbig)
min_n = min(runs.values())

plt.rcParams.update({"font.size": 8, "axes.edgecolor": "#888", "axes.labelcolor": "#222",
                     "xtick.color": "#444", "ytick.color": "#444"})
fig, axes = plt.subplots(2, 2, figsize=(6.3, 4.8), sharex=True)

for ax, (op, metric, ylabel, logy) in zip(axes.flat, PANELS):
    for (key, path), df in data.items():
        color, label = SYSTEMS[key][3], SYSTEMS[key][4]
        g = df[df["op"] == op].groupby("x")[metric]
        q = g.quantile([0.25, 0.5, 0.75]).unstack()
        q = q[g.count() >= min_n]
        x = q.index.to_numpy()
        ax.fill_between(x, q[0.25], q[0.75], color=color, alpha=0.12, linewidth=0)
        ax.plot(x, q[0.5], color=color, linewidth=1.3, markersize=2.5,
                label=label, marker="o")
    ax.set_ylabel(ylabel)
    ax.set_xscale("log", base=2)
    if logy:
        ax.set_yscale("log")
    else:
        ax.set_ylim(bottom=0)
    ax.grid(True, which="major", axis="y", color="#ddd", linewidth=0.6)
    ax.spines[["top", "right"]].set_visible(False)


def fmt(v, _):
    for u in ("B", "KiB", "MiB", "GiB"):
        if v < 1024:
            return f"{v:.0f}{u}"
        v /= 1024
    return f"{v:.0f}TiB"


for ax in axes[1]:
    ax.xaxis.set_major_locator(mticker.LogLocator(base=16))
    ax.xaxis.set_major_formatter(mticker.FuncFormatter(fmt))
    ax.set_xlabel("allocation size")

from matplotlib.lines import Line2D
sys_handles = [Line2D([], [], color=c, linewidth=2, label=l) for (_, _, _, c, l) in SYSTEMS.values()]
fig.legend(handles=sys_handles, loc="upper center", ncol=3, frameon=False,
           bbox_to_anchor=(0.5, 1.0), columnspacing=1.0, handlelength=2.4)
fig.tight_layout(rect=(0, 0, 1, 0.94))
fig.savefig(OUT + ".pdf")
fig.savefig(OUT + ".png", dpi=160)
print("boots per target:", {f"{k}/{p}": n for (k, p), n in runs.items()})
