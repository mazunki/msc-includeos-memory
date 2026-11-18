{
  includeos,
  vmrunner ? includeos.vmrunner,
  chainloader ? includeos.chainloader,
  zig ? includeos.pkgs.zig,
  zls ? null,
  doBuild ? true,
}:
let
  stdenv = includeos.stdenv;
  pkgs = includeos.pkgs;
in
pkgs.mkShell.override { inherit (includeos) stdenv; } rec {
  packages = [
    vmrunner
    zig
    pkgs.buildPackages.cmake
    pkgs.buildPackages.nasm
    pkgs.pkgsIncludeOS.suppressTargetWarningHook
    pkgs.qemu
    pkgs.which
    pkgs.grub2
    pkgs.iputils
  ] ++ pkgs.lib.optional (zls != null) zls;

  buildInputs = [
    includeos
    chainloader
  ];

  cmakeFlags = [
    "-DINCLUDEOS_PACKAGE=${includeos}"
    "-DCMAKE_MODULE_PATH=${includeos}/cmake"
    "-DFOR_PRODUCTION=off"
    "-DARCH=x86_64"
    "-DCMAKE_VERBOSE_MAKEFILE:BOOL=ON"
    "-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"
    "-DCMAKE_LINKER=${stdenv.cc}/bin/${stdenv.cc.targetPrefix}ld"  # prevents dirty system PATH issues
  ];

  shellHook = if doBuild then ''
    cmake src/CMakeLists.txt -B ./build $cmakeFlags
    cmake --build ./build

    echo "To run the hello_includeos unikernel:"
    echo " boot ./build/hello_includeos.elf.bin"
  '' else ''
    echo "To build and run the hello_includeos unikernel:"
    echo " cmake src/CMakeLists.txt -B ./build $cmakeFlags"
    echo " cmake --build ./build"
    echo " boot ./build/hello_includeos.elf.bin"
  '';
}
