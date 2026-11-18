# syscall-latency

Cycles per `malloc`, `mmap` and `getpid`/`gettid` on IncludeOS and Linux, under KVM and TCG.
Tables 6.4–6.6, Figure 6.1. IncludeOS: tag `msc-syscall-latency` (`4695cf572`).

    cd src
    ./run.sh measure 30          # writes results.json
    python3 plot.py results.json > syscall-latency-plot.tex

`results/testctrl.json`: 30 runs per variant.
