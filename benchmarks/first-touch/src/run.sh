#!/bin/sh
set -eu
cd "$(dirname "$0")"

export USE_KVM=true
export COUNT="${COUNT:-30}"
TAG="${TAG:-run}"
mkdir -p "results-${TAG}"

for v in original thesis; do
  rm -rf benchmarks builds
  inc="${INCLUDEOS_ROOT:-${HOME}}/IncludeOS-${v}"

  echo "=== $(date -Is) includeos-${v}"
  nix-shell --arg includeos "${inc}" --run "env INCLUDEOS=${inc} ./test.sh includeos"
  nix-shell --arg includeos "${inc}" --run "env INCLUDEOS=${inc} ./test.sh includeos_native"
  mv benchmarks "results-${TAG}/includeos-${v}"
done

rm -rf benchmarks
echo "=== $(date -Is) linux"
./test.sh linux
./test.sh linux_native
mv benchmarks "results-${TAG}/linux"

echo "=== $(date -Is) done"
