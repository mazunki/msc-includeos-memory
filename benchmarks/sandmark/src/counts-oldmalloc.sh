#!/usr/bin/env bash
# Local, not testctrl: call counts are deterministic.
# 1. Linux call counts, with the oldmalloc builds.
# 2. Who calls mmap on Linux: musl's malloc or the OCaml runtime directly.
# Run from the Sandmark flake directory. Needs gdb.
set -euo pipefail
export PATH=/nix/var/nix/profiles/default/bin:$PATH
here=$(cd "$(dirname "$0")" && pwd)
out=counts-$(date +%F)-oldmalloc
mkdir -p "$out/linux-strace" "$out/mmap-callers"
benches="almabench bdd hamming soli kb kb_no_exc sequence_cps dka crout qr rec_seq_fib rec_seq_tak rec_seq_ack rec_seq_motzkin rec_seq_sudan alloc morestacks lazy_primes"

for b in $benches; do
  bin=$(nix build --no-link --print-out-paths ".#packages.x86_64-linux.$b-linux")/bin/hello_linux
  strace -f -e trace=mmap,munmap,brk,mremap,mprotect,madvise,write,writev \
    -o "$out/linux-strace/$b.trace" "$bin" >/dev/null 2>&1 &
done
wait
python3 "$here/count-linux.py" "$out/linux-strace" > "$out/linux-counts.json"

# Immediate caller of every mmap, from the return address on entry to __mmap.
for b in $benches; do
  bin=$(nix build --no-link --print-out-paths ".#packages.x86_64-linux.$b-linux")/bin/hello_linux
  gdb -q -batch -x "$here/mmap-callers.gdb" "$bin" 2>&1 \
    | grep ' in section ' | sed 's/ + [0-9]* in section.*//' \
    | sort | uniq -c | sort -rn > "$out/mmap-callers/$b.txt"
  echo "== $b"; cat "$out/mmap-callers/$b.txt"
done | tee "$out/mmap-callers.txt"
