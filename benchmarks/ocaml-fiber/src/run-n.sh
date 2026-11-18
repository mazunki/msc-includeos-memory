#!/bin/sh
set -eu

app="${1}"
n="${2}"
shift 2

for _ in $(seq "${n}"); do
  nix run ".#${app}" -- "$@"
  echo "---RUN-END---"
done
