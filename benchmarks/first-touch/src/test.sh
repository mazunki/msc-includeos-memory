#!/bin/sh
set -eu

COUNT=${COUNT:-10}
KERNEL=${KERNEL:-/nix/store/303izw3zmxza3n01blxaa5a44abbqkkr-linux-6.12.30/bzImage}
VM_JSON=${VM_JSON:-bench/vm.json}
BUILDS_DIR=${BUILDS_DIR:-./builds}
BENCH_DIR=${BENCH_DIR:-./benchmarks}
USE_KVM=${USE_KVM:-false}

die() { printf '%s\n' "$*" >&2; exit 1; }

${USE_KVM} && __USE_KVM=1 || __USE_KVM=

boot_linux() {
  (set -x; qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$1" \
    -m 4G \
    -nographic \
    -append "console=ttyS0 rdinit=/sbin/init root=/dev/ram0 rw" \
    ${__USE_KVM:+-enable-kvm} ${xxx:-} \
    ${__USE_KVM:+-cpu kvm64,+rdrand,+rdseed} ${xxx:-} \
  )
}

boot_includeos() {
  (set -x; boot ${__USE_KVM:+--kvm} -j "$VM_JSON" "$1")
}

log() {
  if ${USE_KVM}; then
    out="$BENCH_DIR/$1-$2-kvm"
  else
    out="$BENCH_DIR/$1-$2-emulated"
  fi
  # tee /dev/stderr |
  tee "${out}.log" >/dev/null
}

repeat() {
  # repeat <name> <boot_fn> <image>
  name=$1
  boot_fn=$2
  image=$3

  i=1
  while [ "$i" -le "$COUNT" ]; do
    "$boot_fn" "$image" | log "$name" "$i"
    printf $i.
    i=$((i + 1))
  done
  printf '\n'
}

prepare_includeos() {
  # prepare_includeos <builddir> <is_native: bool>
  builddir=$1
  is_native=$2

  cmake_args=""
  if "$is_native"; then
    cmake_args="-DNATIVE_MALLOC=ON"
  fi

  nix-shell --arg includeos "${INCLUDEOS:?set INCLUDEOS}" --run \
    "cmake -S bench -B '$builddir' $cmake_args && cmake --build '$builddir'"
}

test_includeos() {
  # test_includeos <subdir> <is_native: bool>
  subdir=$1
  is_native=$2

  mkdir -p "$BUILDS_DIR" "$BENCH_DIR"
  builddir="$BUILDS_DIR/$subdir"

  echo "building includeos (native=$is_native)"
  prepare_includeos "$builddir" "$is_native"
  echo "running $COUNT times"

  repeat "$subdir" boot_includeos "$builddir/hello.elf.bin"
}

prepare_linux() {
  # prepare_linux <is_native: bool>
  is_native=$1

  out=$(nix-build --no-out-link -E "
    let x = import ./cc-musl-linux.nix;
    in x.mkInitrd { nativeMalloc = ${is_native}; }
  ") || die "nix-build failed"

  printf '%s\n' "$out/initrd.cpio"
}

test_linux() {
  # test_linux <subdir> <is_native: bool>
  subdir=$1
  is_native=$2

  mkdir -p "$BENCH_DIR"
  echo "preparing initrd (native=$is_native)"
  initrd=$(prepare_linux "$is_native")

  echo "running $COUNT times"
  repeat "$subdir" boot_linux "$initrd"
}

process_csv_headers() {
  for file in benchmarks/*.log; do
    tr -d '\r' < "${file}" |
    awk '/==BEGIN_TRACE==/,/==END_TRACE==/' >"${file%.log}.csv"
    sed -i '/^==.*==$/d' "${file%.log}.csv"
  done
}

usage() {
  cat >&2 <<EOF
Usage: $0 {includeos|includeos_native|linux|linux_native}
EOF
  exit 2
}

target=${1:-}
case "$target" in
  includeos)
    test_includeos unikernel false
    ;;
  includeos_native)
    test_includeos unikernel-native true
    ;;
  linux)
    test_linux linux false
    ;;
  linux_native)
    test_linux linux-native true
    ;;
  cleanup)
    process_csv_headers ; exit ;;
  ""|-h|--help)
    usage
    ;;
  *)
    die "Unknown target: $target"
    ;;
esac

process_csv_headers
