{
  withCcache ? false, # Enable ccache support
  smp ? false, # Enable SMP support
  includeos,
  myOcaml ? import ./ocaml.nix { inherit includeos; },
}:

includeos.stdenv.mkDerivation rec {
  pname = "ocaml_example";
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
  ];

  version = "dev";
}
