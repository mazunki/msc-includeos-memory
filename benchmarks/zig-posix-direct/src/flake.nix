{
  description = "Zig <-> IncludeOS hello world";

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

    unikernel = pkgs.callPackage ./default.nix { includeos = includeosPkg; zig = zigPkg; benchSize = 65536; };

    bootScript = pkgs.writeShellScriptBin "boot-zig-hello-world" ''
      export INCLUDEOS_CHAINLOADER="${ios.chainloader}/bin"
      export PATH="${pkgs.qemu}/bin:${pkgs.grub2}/bin:$PATH"
      BINARY="${unikernel}/bin/allocator_path_includeos_batched_zig.elf.bin"
      if [ "$#" -gt 0 ]; then
        case "$1" in
          -*) ;;
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

    remoteDir = "zig-allocator-path-bench";

    push = pkgs.writeShellApplication {
      name = "push";
      runtimeInputs = [ pkgs.rsync ];
      text = ''
        echo "== pushing to testctrl:${remoteDir} =="
        rsync -az --delete \
          --exclude .git --exclude .jj \
          --exclude build --exclude result --exclude 'result-*' \
          --exclude bench-results --exclude bench-results-testctrl \
          --exclude 'results-*.json' --exclude results.json \
          ./ "testctrl:${remoteDir}/"
      '';
    };

    pull = pkgs.writeShellApplication {
      name = "pull";
      runtimeInputs = [ pkgs.rsync ];
      text = ''
        echo "== pulling bench-results from testctrl:${remoteDir} =="
        mkdir -p bench-results-testctrl
        rsync -az "testctrl:${remoteDir}/bench-results/" ./bench-results-testctrl/
        echo "saved to ./bench-results-testctrl"
      '';
    };

    testctrl = pkgs.writeShellApplication {
      name = "testctrl";
      runtimeInputs = [ pkgs.openssh pkgs.rsync ];
      text = ''
        ${push}/bin/push

        echo "== building + booting the full sweep on testctrl (needs /dev/kvm there) =="
        ssh testctrl bash -s <<REMOTE
        set -euo pipefail
        cd "${remoteDir}"
        export PATH="/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
        ./run.sh "''${N_RUNS:-30}"
        REMOTE

        ${pull}/bin/pull
      '';
    };
  in
  {
    packages.${system} = {
      default = unikernel;
      unikernel = unikernel;
      boot = bootScript;
      push = push;
      pull = pull;
      testctrl = testctrl;
    };

    apps.${system} = {
      default = { type = "app"; program = "${bootScript}/bin/boot-zig-hello-world"; };
      boot = { type = "app"; program = "${bootScript}/bin/boot-zig-hello-world"; };
      push = { type = "app"; program = "${push}/bin/push"; };
      pull = { type = "app"; program = "${pull}/bin/pull"; };
      testctrl = { type = "app"; program = "${testctrl}/bin/testctrl"; };
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
