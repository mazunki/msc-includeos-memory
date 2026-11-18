{
  withCcache ? false, # Enable ccache support
  smp ? false, # Enable SMP support
  includeos ? import ./includeos.nix { inherit smp; inherit withCcache; },
  zig ? includeos.pkgs.zig,
  benchSize, # allocation size in bytes
}:

includeos.stdenv.mkDerivation rec {
  pname = "allocator_path";
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
    "-DBENCH_SIZE=${toString benchSize}"
  ];

  # vm.json isn't a cmake target; vmrunner needs it next to the image
  postInstall = ''
    cp ${src}/vm.json $out/bin/vm.json
  '';

  version = "dev";
}
