# ocaml-fiber

OCaml 5.3 fiber scheduler (7 fibers, round-robin) on IncludeOS and Linux,
timing `caml_startup` and the workload. Tables 6.10–6.13.

    cd src
    INCLUDEOS=<IncludeOS checkout> ./run.sh            # -> ../results/timing-<date>/
    ./compare-native.py                                # Linux builds natively, pinned to one core

- `results/timing-2026-11-14/`: one run on testctrl against the IncludeOS `msc-thesis`
  branch (`c74860bf2`). `results.json`: Tables 6.10 and 6.13;
  `*-trimmed.log`, `*-matched.log`, `*-stock.log`: Table 6.12.
- `results/mapstack-native/summary.txt`: Table 6.11; only the summary was kept.
