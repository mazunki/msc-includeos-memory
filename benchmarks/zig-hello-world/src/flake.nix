{
  description = "Zig <-> IncludeOS hello world: minimal proof that a Zig object file links against IncludeOS and can call os::mem::raw_allocator()";

  inputs = {
    zig-toolchain.url = "github:mazunki/zig-toolchain";
    includeos.url = "github:mazunki/IncludeOS?ref=dev";
    vmrunner.url = "github:mazunki/vmrunner";
  };

  outputs = { self, zig-toolchain, includeos, vmrunner }:
  let
    system = "x86_64-linux";

    ios = includeos.lib.${system}.mkIncludeos { };
    includeosPkg = ios.includeos // {
      pkgs = ios.pkgs;
      pkgsStatic = ios.pkgs.pkgsStatic;
      stdenv = ios.stdenvIncludeOS.stdenv;
      chainloader = ios.chainloader;
    };
    pkgs = ios.pkgs;

    vmrunnerPkg = vmrunner.packages.${system}.default;
    zigPkg = zig-toolchain.packages.${system}.zig;

    unikernel = pkgs.callPackage ./default.nix { includeos = includeosPkg; zig = zigPkg; };

    bootScript = pkgs.writeShellScriptBin "boot-zig-hello-world" ''
      export INCLUDEOS_CHAINLOADER="${ios.chainloader}/bin"
      export PATH="${pkgs.qemu}/bin:${pkgs.grub2}/bin:$PATH"
      BINARY="${unikernel}/bin/hello_includeos.elf.bin"
      if [ "$#" -gt 0 ]; then
        case "$1" in
          -*) ;; # looks like a flag (e.g. --kvm), not a binary path
          *)
            if [ ! -e "$1" ]; then
              echo "boot-zig-hello-world: '$1' does not look like a flag and does not exist as a file" >&2
              exit 1
            fi
            BINARY="$1"
            shift
            ;;
        esac
      fi
      # vmrunner only looks for ./vm.json relative to cwd, so cd there first.
      cd "$(dirname "$BINARY")"
      exec ${vmrunnerPkg}/bin/boot "./$(basename "$BINARY")" "$@"
    '';
  in
  {
    packages.${system} = {
      default = unikernel;
      unikernel = unikernel;
      boot = bootScript;
    };

    apps.${system} = {
      default = { type = "app"; program = "${bootScript}/bin/boot-zig-hello-world"; };
      boot = { type = "app"; program = "${bootScript}/bin/boot-zig-hello-world"; };
    };

    devShells.${system}.default = import ./shell.nix {
      includeos = includeosPkg;
      chainloader = ios.chainloader;
      vmrunner = vmrunnerPkg;
      zig = zigPkg;
      zls = zig-toolchain.packages.${system}.zls;
    };
  };
}
