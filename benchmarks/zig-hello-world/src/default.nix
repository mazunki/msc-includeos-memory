{
  withCcache ? false, # Enable ccache support
  smp ? false, # Enable SMP support
  includeos, # from the flake
  zig ? includeos.pkgs.zig,
}:

includeos.stdenv.mkDerivation rec {
  pname = "zig_hello_world";
  src = includeos.pkgs.lib.cleanSource ./bench;

  nativeBuildInputs = [
    includeos.pkgsStatic.buildPackages.nasm
    includeos.pkgsStatic.buildPackages.cmake
    includeos.pkgsStatic.buildPackages.binutils
    zig
  ];

  buildInputs = [
    includeos
  ];

  cmakeFlags = [
    "-DINCLUDEOS_PACKAGE=${includeos}"
    "-DCMAKE_MODULE_PATH=${includeos}/cmake"
    "-DFOR_PRODUCTION=off"
    "-DARCH=x86_64"
    "-DCMAKE_VERBOSE_MAKEFILE:BOOL=ON"
  ];

  # vm.json isn't a cmake target; vmrunner needs it next to the image
  postInstall = ''
    cp ${src}/vm.json $out/bin/vm.json
  '';

  version = "dev";
}
