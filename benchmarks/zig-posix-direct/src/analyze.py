#!/usr/bin/env python3
"""Print zig-vs-cpp cost tables from a bench.py results.json.

Usage:
  ./analyze.py <results.json>

batched/interleaved: one value per boot, boots slower than 3x the median dropped.
fill/interleaved_fill: per-allocation values pooled across boots, unfiltered.
"""
import json
import re
import statistics as st
import sys
from collections import defaultdict

GROUPS = [
    ("batched", ["batched", "fill"]),
    ("interleaved", ["interleaved", "interleaved_fill"]),
]

FIXED_TOTAL_OPS = 2000  # main.cpp: static constexpr size_t total_ops = 2000;


def load_data(path):
    data = json.load(open(path))

    # (size, allocator, workload, op, lang) -> list of values to compute cost stats over
    values = defaultdict(list)
    # (size, allocator, workload, lang) -> exhaustion count (one value per boot)
    counts = defaultdict(list)

    avg_re = re.compile(r'^(\w+)\.(alloc|free)(_interleaved)?\.(\d+)$')
    idx_re = re.compile(r'^(\w+)\.(fill|interleaved_fill)_(alloc|free)\.(\d+)\.(\d+)$')
    count_re = re.compile(r'^(\w+)\.(fill_count|interleaved_fill_alloc_count)\.(\d+)$')

    for rec in data:
        for k, v in rec.items():
            m = avg_re.match(k)
            if m:
                lang_alloc, op, interleaved, size = m.groups()
                lang, allocator = lang_alloc.split('_', 1)
                workload = 'interleaved' if interleaved else 'batched'
                values[(int(size), allocator, workload, op, lang)].append(v)
                continue
            m = idx_re.match(k)
            if m:
                label_prefix, workload, op, size, idx = m.groups()
                lang, allocator = label_prefix.split('_', 1)
                values[(int(size), allocator, workload, op, lang)].append(v)
                continue
            m = count_re.match(k)
            if m:
                label_prefix, count_kind, size = m.groups()
                lang, allocator = label_prefix.split('_', 1)
                workload = 'fill' if count_kind == 'fill_count' else 'interleaved_fill'
                counts[(int(size), allocator, workload, lang)].append(v)

    return values, counts


def stat_for(values, key, stat):
    vals = values.get(key)
    if not vals:
        return None
    size, allocator, workload, op, lang = key
    if workload in ("batched", "interleaved"):
        median = st.median(vals)
        vals = [v for v in vals if v < median * 3]
    return stat(vals)


def count_for(counts, size, allocator, workload, lang):
    if workload in ("batched", "interleaved"):
        return FIXED_TOTAL_OPS
    vals = counts.get((size, allocator, workload, lang))
    return st.mean(vals) if vals else None


def all_rows(values, workloads, op):
    rows = set((size, workload) for (size, allocator, workload, o, lang) in values
               if o == op and workload in workloads)
    return sorted(rows, key=lambda r: (r[0], r[1]))


def print_table(values, counts, workloads, op, stat, stat_name):
    print(f"=== {op} ({stat_name}) ===")
    print(f"{'count':>9} {'size':>9}  {'zig_posix':>10} {'cpp_posix':>10} {'ratio':>7}    {'zig_direct':>11} {'cpp_direct':>10} {'ratio':>7}")
    for size, workload in all_rows(values, workloads, op):
        pz = stat_for(values, (size, 'posix', workload, op, 'zig'), stat)
        pc = stat_for(values, (size, 'posix', workload, op, 'cpp'), stat)
        dz = stat_for(values, (size, 'includeos', workload, op, 'zig'), stat)
        dc = stat_for(values, (size, 'includeos', workload, op, 'cpp'), stat)
        if None in (pz, pc, dz, dc):
            continue
        pr = pz / pc
        dr = dz / dc
        # count is identical across lang/allocator (shared pool, fixed total_ops) --
        # take zig/posix's as representative.
        count = count_for(counts, size, 'posix', workload, 'zig')
        print(f"{count:>9.0f} {size:>9}  {pz:>10.1f} {pc:>10.1f} {pr:>6.2f}x    {dz:>11.1f} {dc:>10.1f} {dr:>6.2f}x")
    print()


def main():
    if len(sys.argv) != 2:
        print("usage: ./analyze.py <results.json>", file=sys.stderr)
        sys.exit(1)
    values, counts = load_data(sys.argv[1])
    print("comptime: batched=no, interleaved=yes, fill=yes, interleaved_fill=yes")
    print("count: total_ops=2000 (fixed input) for batched/interleaved; exhaustion count (measured) for fill/interleaved_fill\n")
    for group_name, workloads in GROUPS:
        print(f"##### {group_name} #####\n")
        for op in ["alloc", "free"]:
            print_table(values, counts, workloads, op, st.mean, "mean")
            print_table(values, counts, workloads, op, st.median, "median")


if __name__ == "__main__":
    main()
