{
  withCcache ? false,
  smp ? false,
  includeos,
  myOcaml ? import ./ocaml.nix { inherit includeos; },
  benchmarkMl,  # required: absolute path to the .ml benchmark file
}:

includeos.stdenv.mkDerivation rec {
  pname = "ocaml_sandmark";
  src = includeos.pkgs.lib.cleanSource ./bench;

  nativeBuildInputs = [
    includeos.pkgsStatic.buildPackages.nasm
    includeos.pkgsStatic.buildPackages.cmake
    includeos.pkgsStatic.buildPackages.binutils
  ];

  buildInputs = [
    includeos
    myOcaml
  ];

  cmakeFlags = [
    "-DOCAML=${myOcaml}"
    "-DINCLUDEOS_PACKAGE=${includeos}"
    "-DFOR_PRODUCTION=off"
    "-DARCH=x86_64"
    "-DCMAKE_VERBOSE_MAKEFILE:BOOL=ON"
    "-DBENCHMARK_ML_FILE=${benchmarkMl}"
  ];

  version = "dev";
}
