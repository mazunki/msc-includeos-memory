#!/usr/bin/env python3
"""usage: count-linux.py TRACE_DIR > linux-counts.json"""
import glob, json, os, re, sys

out = {}
for f in sorted(glob.glob(f"{sys.argv[1]}/*.trace")):
    b = os.path.basename(f)[:-6]
    on, c = False, {}
    for line in open(f):
        if re.search(r"writev?\(", line) and "[bench start]" in line:
            on = True
            continue
        if re.search(r"writev?\(", line) and "[bench end]" in line:
            on = False
            continue
        if not on:
            continue
        m = re.match(r"\d+\s+(\w+)\(", line)
        if not m or m.group(1) in ("write", "writev"):
            continue
        k = m.group(1)
        if k == "mmap" and "MAP_FIXED" in line:
            k = "mmap_fixed"
        c[k] = c.get(k, 0) + 1
    out[b] = c
json.dump(out, sys.stdout)
