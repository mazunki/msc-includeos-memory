# cc-musl-linux.nix
let
  pkgs = import ./pinned.nix;
  lib = pkgs.lib;
  muslPkgs = pkgs.pkgsMusl;

  packDeps = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.cpio
  ];

  mkHello = { nativeMalloc ? false }:
    muslPkgs.stdenv.mkDerivation {
      pname = "hello";
      version = "1";
      src = ./bench;

      nativeBuildInputs = [
        pkgs.cmake
        pkgs.gnumake
      ];

      cmakeFlags =
        [ "-DON_LINUX=ON" ]
        ++ lib.optional nativeMalloc "-DNATIVE_MALLOC=ON";
    };

  mkInitrd = { nativeMalloc ? false }:
    pkgs.stdenvNoCC.mkDerivation {
      pname = "initrd";
      version = "1";
      src = ./initrd;

      nativeBuildInputs = packDeps;
      hello = mkHello { inherit nativeMalloc; };

      dontUnpack = true;
      installPhase = ''
        mkdir -p "$out"

        cp -a "$src" initrd-out
        chmod -R u+w initrd-out

        mkdir -p initrd-out/bin
        cp "$hello/bin/hello" initrd-out/bin/hello

        (cd initrd-out && find . -print | cpio -o -H newc) > "$out/initrd.cpio"
      '';
    };

in {
  shell = muslPkgs.mkShell {
    packages = [
      pkgs.cmake pkgs.gnumake
      pkgs.coreutils pkgs.findutils pkgs.cpio
    ];
  };

  inherit mkHello mkInitrd;
  buildInitrd = mkInitrd { nativeMalloc = false; };
  buildInitrdNative = mkInitrd { nativeMalloc = true; };
}
