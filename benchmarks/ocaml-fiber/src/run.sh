#!/bin/sh
set -eu
cd "$(dirname "$0")"

ios="${INCLUDEOS:-${HOME}/IncludeOS-thesis}"
n="${N:-30}"
out="../results/timing-$(date +%F)"

sed -i "s|includeos.url = \".*\";|includeos.url = \"path:${ios}\";|" flake.nix
nix flake lock

mkdir -p "${out}"
nix flake metadata --json > "${out}/flake-metadata.json"
uname -a > "${out}/host"
git -C "${ios}" describe --always --dirty > "${out}/includeos-rev" 2>/dev/null || true

rm -f results.json
BENCH_VARIANTS=includeos.kvm,linux.kvm,linux.unpatched.kvm \
  python3 bench.py measure "${n}" 2>&1 | tee "${out}/measure.log"
mv results.json "${out}/"

./run-n.sh includeos "${n}" --kvm > "${out}/includeos-trimmed.log"
./run-n.sh includeos-mapstack "${n}" --kvm > "${out}/includeos-matched.log"
timeout 120 ./run-n.sh includeos-stock 1 --kvm > "${out}/includeos-stock.log" 2>&1 || true
./run-n.sh linux.nomapstack.kvm "${n}" > "${out}/linux-trimmed.log"
./run-n.sh linux.kvm "${n}" > "${out}/linux-matched.log"
./run-n.sh linux.unpatched.kvm "${n}" > "${out}/linux-stock.log"

echo "done: ${out}"
