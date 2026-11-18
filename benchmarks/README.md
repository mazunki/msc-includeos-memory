# benchmarks

Benchmarks and raw results for the thesis on memory management in IncludeOS.
Each directory has `src/` (what was run) and `results/` (what came out).

| directory | thesis section |
|---|---|
| [syscall-latency](syscall-latency) | 6.4.1–6.4.3: `malloc`, `mmap` and syscall latency |
| [first-touch](first-touch) | 6.4.4: commit and first-touch cost |
| [ocaml-fiber](ocaml-fiber) | 6.5.1–6.5.2: OCaml fiber workload |
| [sandmark](sandmark) | 6.5.3: Sandmark |
| [zig-hello-world](zig-hello-world) | 6.6: Zig feasibility |
| [zig-posix-direct](zig-posix-direct) | 6.7: allocation latency, POSIX vs direct |
| [arena-buddy](arena-buddy) | 6.8: arena vs buddy |
| [boot-trace](boot-trace) | 2.5, 4.1: the IncludeOS startup sequence, traced with GDB (a document, no results) |

Timed runs were on testctrl (Ryzen 9 7900X), under QEMU/KVM with 4 GiB and
`-cpu kvm64,+rdrand,+rdseed`, unless a README says otherwise.

IncludeOS comes from [mazunki/IncludeOS](https://github.com/mazunki/IncludeOS):

| ref | commit | used by |
|---|---|---|
| branch `msc-thesis` | `c74860bf2` | first-touch, ocaml-fiber, sandmark, arena-buddy |
| tag `msc-syscall-latency` | `4695cf572` | syscall-latency |
| tag `msc-zig` | `dbe3ecf1d` | zig-hello-world, zig-posix-direct |
| tag `msc-original` | `c02be0c67` | the original IncludeOS in the microbenchmarks |
