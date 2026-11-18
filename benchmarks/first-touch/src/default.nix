{ withCcache ? false
, smp ? false
, includeos ? import (builtins.fetchGit {
    url = "https://github.com/includeos/IncludeOS.git";
    ref = "main";
  }) { inherit smp withCcache; }
}:

let
  stdenv = includeos.stdenv;
  pkgs = includeos.pkgs;
  pkgsStatic = includeos.pkgsStatic;
in
stdenv.mkDerivation {
  pname = "includeos-hello";
  version = "dev";
  src = ./bench;

  nativeBuildInputs = [
    stdenv.cc
    pkgs.buildPackages.cmake
    pkgs.buildPackages.nasm
  ] ++ (includeos.nativeBuildInputs or []);

  buildInputs = [
    includeos
    includeos.chainloader
  ];
}
