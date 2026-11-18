# sandmark

18 single-file programs from Sandmark (upstream `5605805` plus
`src/sandmark-output.patch`, which makes them print checkable output), on IncludeOS, on Linux
with the same OCaml flags, and on Linux with stock OCaml 5.3. Tables 6.14–6.15.
IncludeOS: `msc-thesis` branch (`c74860bf2`).

    cd src
    ./run.sh                   # on testctrl -> ../results/timing-<date>-oldmalloc/

Call counts (Table 6.15), IncludeOS: apply `count-calls.patch`, boot each
program once and read the counters. Linux: `./counts-oldmalloc.sh` (strace,
and which function called each `mmap`, via `mmap-callers.gdb`).

- `results/timing-2026-11-01-oldmalloc/`: Table 6.14, 30 runs per program and
  variant, with outputs in `validate_output/`. Linux is built with clang 20 and
  musl's oldmalloc.
- `results/timing-2026-11-02-oldmalloc-lazy_primes/`: `lazy_primes` again with
  n = 3000, which replaces its row from the run above.
- `results/calls/includeos/`: IncludeOS allocator counters for Table 6.15
  (2026-10-22, local KVM).
- `results/calls/linux-oldmalloc-2026-11-02/`: Linux strace counts for Table 6.15,
  and `mmap` callers. Counted before `lazy_primes` got its argument, so its row
  there is from n = 1.

`results/small-memory-2026-11-02/` (`src/small-memory-boots.sh`, not in the
thesis): `soli` booted with 32 MiB to 16 GiB. Up to 512 MiB, OCaml panics with
"Not enough heap memory to reserve minor heaps", since its heap reservation is
backed in full; from 1 GiB it boots.

`lazy_primes` reads its size from argv and finishes almost at once without
one, so `flake.nix` passes it 3000, as Sandmark's own run configs do
(`defaultArgv`). `includeos`, `compiler` and `sandmark` in `flake.nix` point at
local checkouts.
