#!/usr/bin/env bash
# N=10 for a quick trial, BENCHES="lazy_primes" for a subset
set -euo pipefail
export PATH="/nix/var/nix/profiles/default/bin:${PATH}"
cd "$(dirname "$0")"

n="${N:-30}"
read -ra benches <<< "${BENCHES:-}"
ios="${INCLUDEOS:-${HOME}/IncludeOS-thesis}"

# flake.nix points at local checkouts; repoint them elsewhere
if [ ! -e /home/maz/repos/includeos/IncludeOS-thesis ]; then
  sm="${SANDMARK:-${HOME}/sandmark-rerun/sandmark}"
  # needs the uncommitted toolchain.nix fix for oldmalloc
  cc="${COMPILER:-${HOME}/compiler}"
  sed -i \
    -e "s|path:/home/maz/repos/includeos/IncludeOS-thesis|path:${ios}|" \
    -e "s|path:/home/maz/repos/mazunki/compiler|path:${cc}|" \
    -e "s|git+file:///home/maz/repos/MagnusS/runtimes/sandmark|git+file://${sm}?rev=9028acf891215bc8a21a7a42709bda4580e56bae|" \
    flake.nix
  nix flake lock
fi

suffix="${BENCHES:+-${BENCHES// /-}}"
out="../results/timing-$(date +%F)-oldmalloc${suffix}"
mkdir -p "${out}"
nix flake metadata --json > "${out}/flake-metadata.json"
git -C "${ios}" describe --always --dirty > "${out}/includeos-rev" 2>/dev/null || true
uname -a > "${out}/host"

# __bin_chunk only exists in oldmalloc
for pkg in alloc-linux alloc-linux-unpatched; do
  bin="$(nix build --no-link --print-out-paths ".#packages.x86_64-linux.${pkg}")/bin/hello_linux"
  # not grep -q: closing the pipe early trips pipefail
  if nm "${bin}" | grep ' __bin_chunk$' > /dev/null; then
    echo "${pkg}: oldmalloc"
  else
    echo "${pkg}: NOT oldmalloc, stopping"
    exit 1
  fi
done | tee "${out}/malloc-check"

# bench.py merges into results.json
if [ -f results.json ]; then
  mv results.json "results.json.before-$(date +%F)"
fi

python3 bench.py validate "${benches[@]}" 2>&1 | tee "${out}/validate.log"
BENCH_VARIANTS=linux.kvm,linux.unpatched.kvm,includeos.kvm \
  python3 bench.py measure "${benches[@]}" "${n}" 2>&1 | tee "${out}/run.log"
python3 bench.py stats > "${out}/stats.txt" 2>&1 || true

mv results.json "${out}/"
if [ -d validate_output ]; then
  mv validate_output "${out}/"
fi

echo "done: ${out}"
