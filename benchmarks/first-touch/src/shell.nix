{ withCcache ? false
, smp ? false
, vmrunner ? null
, includeos ? null }:

let
  includeOS =
    if includeos == null then
      import (builtins.fetchGit {
        url = "https://github.com/includeos/IncludeOS.git";
        ref = "main";
      }) { inherit smp withCcache; }
    else
      import (builtins.toPath includeos) { inherit smp withCcache; };

  vmrunnerPkg =
    if vmrunner == null then
      includeOS.vmrunner
    else
      pkgs.callPackage (builtins.toPath vmrunner) {};

  stdenv = includeOS.stdenv;
  pkgs = includeOS.pkgs;
  pkgsStatic = includeOS.pkgsStatic;

  drv = import ./default.nix { inherit withCcache smp; includeos=includeOS; };
in
pkgs.mkShell.override { inherit (includeOS) stdenv; } {
  inputsFrom = [ drv ];

  packages = [
    vmrunnerPkg

    stdenv.cc
    pkgs.buildPackages.cmake
    pkgs.buildPackages.nasm

    pkgs.qemu
    pkgs.which
    pkgs.grub2
    pkgs.iputils
  ];

  buildInputs = [
    includeOS
    includeOS.chainloader
  ];

  bootloader = "${includeOS}/boot/bootloader";
  shellHook = ''
    echo "IncludeOS hello dev shell. Build with:"
    echo "  cmake -S bench -B build && cmake --build build"
  '';
}
