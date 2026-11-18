#!/usr/bin/env bash
set -euo pipefail

# Usage: ./run.sh [N]  -- N boots per (size, allocator), default 100.
# One build per size, both allocator binaries booted separately.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

N="${1:-100}"

# batched/interleaved at small and medium sizes; fill/interleaved_fill from 1 MiB up.
SIZES_BOUNDED=(64 1024 4096 16384 65536 262144 1048576)
SIZES_FILL=(1048576 2097152 4194304 8388608 16777216)

# jq_count sweeps element count, jq_size string length.
COUNTS_JQ=(10 100 1000 10000 100000)
SIZES_JQ=(8 64 512 4096 32768)

ALLOCATORS=(posix includeos)
LANGS=(zig cpp)

# jq workloads have no C++ baseline.
langs_for_workload() {
  case "$1" in
    jq_count|jq_size) echo "zig" ;;
    *) echo "${LANGS[*]}" ;;
  esac
}

declare -A WORKLOADS_FOR_SIZE
for size in "${SIZES_BOUNDED[@]}"; do
  WORKLOADS_FOR_SIZE[${size}]="${WORKLOADS_FOR_SIZE[${size}]:-} batched interleaved"
done
for size in "${SIZES_FILL[@]}"; do
  WORKLOADS_FOR_SIZE[${size}]="${WORKLOADS_FOR_SIZE[${size}]:-} fill interleaved_fill"
done
for size in "${COUNTS_JQ[@]}"; do
  WORKLOADS_FOR_SIZE[${size}]="${WORKLOADS_FOR_SIZE[${size}]:-} jq_count"
done
for size in "${SIZES_JQ[@]}"; do
  WORKLOADS_FOR_SIZE[${size}]="${WORKLOADS_FOR_SIZE[${size}]:-} jq_size"
done

# Union of all sizes, sorted numerically.
mapfile -t ALL_SIZES < <(printf '%s\n' "${!WORKLOADS_FOR_SIZE[@]}" | sort -n)

TOTAL_BOOTS=0
for size in "${ALL_SIZES[@]}"; do
  for workload in ${WORKLOADS_FOR_SIZE[${size}]}; do
    n_langs=$(wc -w <<< "$(langs_for_workload "${workload}")")
    TOTAL_BOOTS=$(( TOTAL_BOOTS + N * n_langs * ${#ALLOCATORS[@]} ))
  done
done

RESULTS_DIR="${REPO_ROOT}/bench-results"
mkdir -p "${RESULTS_DIR}"
export BENCH_RESULTS="${RESULTS_DIR}/results.json"

echo "== run.sh: ${N} boots/combo, ${#ALL_SIZES[@]} sizes, ${TOTAL_BOOTS} total boots ==" >&2
echo "== results -> ${BENCH_RESULTS} ==" >&2

# Resolve the boot script once; evaluating the flake per boot is slow.
echo "== resolving boot script (once) ==" >&2
BOOT_BIN="$(nix build .#boot --no-link --print-out-paths)/bin/boot-zig-hello-world"

for size in "${ALL_SIZES[@]}"; do
  build_dir="${RESULTS_DIR}/build-${size}"
  echo "== building size=${size} (all combos in one configure) ==" >&2
  nix build --impure --expr \
    "(builtins.getFlake (toString ./.)).packages.x86_64-linux.unikernel.override { benchSize = ${size}; }" \
    -o "${build_dir}"

  for allocator in "${ALLOCATORS[@]}"; do
    for workload in ${WORKLOADS_FOR_SIZE[${size}]}; do
      for lang in $(langs_for_workload "${workload}"); do
        binary="${build_dir}/bin/allocator_path_${allocator}_${workload}_${lang}.elf.bin"
        echo "== measuring size=${size} allocator=${allocator} workload=${workload} lang=${lang} (n=${N}) ==" >&2
        python3 "${REPO_ROOT}/bench.py" measure "${N}" \
          "${BOOT_BIN}" "${binary}" --kvm
      done
    done
  done
done

echo "done. results in ${BENCH_RESULTS}" >&2
