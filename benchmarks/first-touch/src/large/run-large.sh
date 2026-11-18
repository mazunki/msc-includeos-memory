#!/bin/sh
set -eu
trap 'echo "=== EXIT status=$? $(date -Is)"' EXIT
cd "$(dirname "$0")/.."
export USE_KVM=true
COUNT_BASE=${COUNT:-10}
export COUNT=$COUNT_BASE
TAG=${TAG:-large}
mkdir -p results-$TAG
for v in thesis original; do
  rm -rf benchmarks builds
  inc=${INCLUDEOS_ROOT:-$HOME}/IncludeOS-$v
  if [ "$v" = original ]; then export COUNT=${COUNT_ORIGINAL:-$COUNT_BASE}; else export COUNT=$COUNT_BASE; fi
  echo "=== $(date -Is) includeos-$v"
  nix-shell --arg includeos "$inc" --run "env INCLUDEOS=$inc ./test.sh includeos_native"
  mv benchmarks results-$TAG/includeos-$v
done
rm -rf benchmarks
echo "=== $(date -Is) linux"
export COUNT=$COUNT_BASE
./test.sh linux_native
mv benchmarks results-$TAG/linux
echo "=== $(date -Is) done"
