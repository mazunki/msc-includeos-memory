#!/usr/bin/env bash
# Boot one IncludeOS image at several memory sizes and
# keep the boot log, for a side-by-side figure of the region layout
# (Magnus: "what about small unikernels", i.e. little memory).
# Runs from its own directory; on testctrl, run run.sh once first
# so flake.nix points at testctrl's checkouts. A later -j overrides vm.json.
set -uo pipefail
export PATH=/nix/var/nix/profiles/default/bin:$PATH
cd "$(dirname "$0")"
bench=${1:-soli}
out=../results/small-memory-$(date +%F)
mkdir -p "$out"
for mb in 32 64 128 256 512 1024 4096 16384; do
  printf '{"mem": %d, "cpu": {"model": "kvm64", "features": ["rdrand", "rdseed"]}}\n' "$mb" > "$out/vm-$mb.json"
  timeout 120 nix run ".#$bench.includeos.kvm" -- -j "$PWD/$out/vm-$mb.json" \
    > "$out/boot-${mb}M.log" 2>&1
  echo "${mb} MiB: exit $? ($(grep -ci 'panic' "$out/boot-${mb}M.log") panic lines)"
done | tee "$out/summary.txt"
