# first-touch

Random `malloc`/`free` sequence over a 1 GiB pool, timing the allocation, the
first write and ten later writes. Custom buddy allocator vs one `mmap` per
allocation, on IncludeOS original (`c02be0c67`), IncludeOS this work
(`msc-thesis` branch, `c74860bf2`) and Linux 6.12.30. Figure 6.2, Tables 6.7–6.9.

    cd src
    INCLUDEOS_ROOT=<dir with IncludeOS-original/ and IncludeOS-thesis/> ./run.sh
    python3 plot.py ../results/sweep first-touch-mmap mmap ../results/large

The 32 MiB–1 GiB sweep (`results/large`) uses `large/main.cpp` in place of
`bench/main.cpp`, run with `large/run-large.sh`.

`results/sweep`: 30 boots per target, 5 seeds per boot (2026-10-18).
`results/large`: 30 boots per system, sizes 32 MiB–1 GiB in powers of two,
in two batches: `*-1xN-*` (10 boots) and `*-2xN-*` (20 boots; IncludeOS
original's 21st was dropped).
