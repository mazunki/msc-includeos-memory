# arena-buddy

Arena, buddy and ring allocators on the same scratch and sliding-window
workloads, one fixed seed. Tables 6.19–6.21, Figures 6.5–6.8.

## What was run

`src/` is the `example/` service from the `msc-thesis` branch of
`mazunki/IncludeOS`. Only `src/src/main.cpp` is built, so to run another
program, copy it over `main.cpp` first.

| program | what it does | output |
|---|---|---|
| `src/main.cpp` | scratch workload on arena, buddy and ring, each in a region carved from the secondary heap; then the sliding-window workload | `boot-logs/carve.txt`, `boot-logs/window.txt`, `*_rawregion_series.dat`, `*_window.dat`, `window_*_full.txt` |
| `src/fragmentation.cpp` | packet workload (`channel.hpp`), buddy heap with and without a ring for the packets | `boot-logs/fragmentation.txt`, `fragmentation/` |
| `src/capacity.cpp` | checks that the primary heap refuses a 6 GiB request and the secondary heap above 4 GiB serves it | not kept |

`src/junk.cpp` has no `main()` and is not used by any result.

## What it was built against

- IncludeOS `msc-thesis` branch (`c74860bf2`). The ring allocator is `snake_resource` there
  (`api/mem/alloc/snake.hpp`), its name at the time.
- Booted with the boot wrapper from `../zig-posix-direct/src`, under KVM.
- VM: 16 GiB (`vm.json`), so that a secondary heap above 4 GiB exists.
  `src/vm.json` (8 GiB) is not used.
- Seed 42, one run per program; the workloads are deterministic.
- Runs: 2026-10-05, on an earlier state of the same changes, so a rerun may
  differ slightly.

## Build and boot

From a checkout of the `msc-thesis` branch:

    nix-build unikernel.nix --arg unikernel <this repo>/arena-buddy/src
    nix run <this repo>/zig-posix-direct/src#boot -- result/hello_includeos.elf.bin --kvm

## Results

- `results/boot-logs/`: full boot output.
- `*_rawregion_series.dat`: Table 6.20, Figure 6.7; `*_window.dat`: Figure 6.8 (`snake` is the ring).
- `fragmentation/`: tile maps for Figures 6.5–6.6 and Table 6.21, drawn with `src/plot-fragmentation.py`.
