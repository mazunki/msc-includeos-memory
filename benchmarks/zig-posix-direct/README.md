# zig-posix-direct

Cycles per allocation and free on IncludeOS, through `mmap` or straight through
`os::mem::raw_allocator()`, from C++ and from Zig's `std.mem.Allocator`.
Tables 6.16–6.18, Figures 6.3–6.4. IncludeOS: tag `msc-zig` (`dbe3ecf1d`).

    cd src
    ./run.sh 30                  # or: nix run .#testctrl
    ./analyze.py results.json

- `results/results-nocomptime-n30.json.xz`: posix vs direct (Tables 6.16–6.17, Figure 6.3).
- `results/results-comptime-n30.json.xz`: the same run with `comptime` allocators (Table 6.18, Figure 6.4).

30 boots per size, allocator and language.
