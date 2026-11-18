{
  description = "ocaml on IncludeOS: startup and memory benchmarks";

  inputs = {
    nixpkgs.url   = "github:NixOS/nixpkgs/25.05";
    includeos.url = "github:mazunki/IncludeOS/dev";
    includeos.inputs.vmrunner.url = "github:mazunki/vmrunner/flakify";
    linux-runner.url = "github:mazunki/linux-runner";
  };

  outputs = { self, nixpkgs, includeos, linux-runner }:
    let
      system = "x86_64-linux";
      mem    = "4G";

      pkgs = import nixpkgs { inherit system; };

      ocaml = pkgs.pkgsStatic.ocaml-ng.ocamlPackages_5_3.ocaml;

      # matches includeos' stuffsies
      patchedOcaml = ocaml.overrideAttrs (old: {
        configureFlags = old.configureFlags ++ [
          "--disable-systhreads"
          "--enable-mmap-map-stack"
          "ac_cv_func_sigprocmask=no"
        ];
      });

      # without --enable-mmap-map-stack
      patchedOcamlNoMapStack = ocaml.overrideAttrs (old: {
        configureFlags = old.configureFlags ++ [
          "--disable-systhreads"
          "ac_cv_func_sigprocmask=no"
        ];
      });

      linux-binary = pkgs.runCommand "hello-linux" {
        nativeBuildInputs = [ ocaml pkgs.pkgsStatic.buildPackages.binutils ];
        CC = "${pkgs.pkgsStatic.stdenv.cc}/bin/${pkgs.pkgsStatic.stdenv.cc.targetPrefix}cc";
      } ''
        mkdir -p build $out/bin
        cp -r ${./bench}/. build/
        cd build
        ${ocaml}/bin/ocamlopt -g -c test_ocaml.ml -o test_ocaml.cmx
        ${ocaml}/bin/ocamlopt -output-obj -g -o ocamlcode.o test_ocaml.cmx
        $CC -static \
          -I${ocaml}/lib/ocaml \
          main_linux.c ocamlcode.o \
          ${ocaml}/lib/ocaml/libasmrun.a \
          -lm -o $out/bin/hello_linux
      '';

      linux-binary-patched = pkgs.runCommand "hello-linux-patched" {
        nativeBuildInputs = [ patchedOcaml pkgs.pkgsStatic.buildPackages.binutils ];
        CC = "${pkgs.pkgsStatic.stdenv.cc}/bin/${pkgs.pkgsStatic.stdenv.cc.targetPrefix}cc";
      } ''
        mkdir -p build $out/bin
        cp -r ${./bench}/. build/
        cd build
        ${patchedOcaml}/bin/ocamlopt -g -c test_ocaml.ml -o test_ocaml.cmx
        ${patchedOcaml}/bin/ocamlopt -output-obj -g -o ocamlcode.o test_ocaml.cmx
        $CC -static \
          -I${patchedOcaml}/lib/ocaml \
          main_linux.c ocamlcode.o \
          ${patchedOcaml}/lib/ocaml/libasmrun.a \
          -lm -o $out/bin/hello_linux
      '';

      linux-binary-nomapstack = pkgs.runCommand "hello-linux-nomapstack" {
        nativeBuildInputs = [ patchedOcamlNoMapStack pkgs.pkgsStatic.buildPackages.binutils ];
        CC = "${pkgs.pkgsStatic.stdenv.cc}/bin/${pkgs.pkgsStatic.stdenv.cc.targetPrefix}cc";
      } ''
        mkdir -p build $out/bin
        cp -r ${./bench}/. build/
        cd build
        ${patchedOcamlNoMapStack}/bin/ocamlopt -g -c test_ocaml.ml -o test_ocaml.cmx
        ${patchedOcamlNoMapStack}/bin/ocamlopt -output-obj -g -o ocamlcode.o test_ocaml.cmx
        $CC -static \
          -I${patchedOcamlNoMapStack}/lib/ocaml \
          main_linux.c ocamlcode.o \
          ${patchedOcamlNoMapStack}/lib/ocaml/libasmrun.a \
          -lm -o $out/bin/hello_linux
      '';

      mkIncludeos     = includeos.lib.${system}.mkIncludeos;
      iosAttrs        = mkIncludeos {};
      iosAttrsDebug   = mkIncludeos { debug = true; };

      mkUnikernel = iosAttrs: extraArgs: (import ./default.nix ({
        includeos = iosAttrs.includeos;
      } // extraArgs)).overrideAttrs (old: {
        buildInputs = old.buildInputs ++ [ iosAttrs.chainloader ];

        installPhase = ''
          runHook preInstall
          find -mindepth 1 -maxdepth 1 -type f -exec install -v -D -t "$out/" {} \;
          find -mindepth 2 -name '*.elf.bin' -exec install -v -t "$out/" {} \;
          runHook postInstall
        '';
      });

      unikernel           = mkUnikernel iosAttrs {};
      unikernel-debug     = mkUnikernel iosAttrsDebug {};
      unikernel-mapstack  = mkUnikernel iosAttrs { myOcaml = patchedOcaml; }; # also --enable-mmap-map-stack
      unikernel-stock     = mkUnikernel iosAttrs { myOcaml = ocaml; };        # no configure flags

      mkIncludeosBoot = includeos.lib.${system}.mkBoot {
        src      = self.packages.${system}.unikernel;
        debugSrc = self.packages.${system}.unikernel-debug;
        kernel   = "hello.elf.bin";
        inherit mem;
      };

      mkIncludeosBootMapstack = includeos.lib.${system}.mkBoot {
        src      = self.packages.${system}.unikernel-mapstack;
        debugSrc = self.packages.${system}.unikernel-mapstack;
        kernel   = "hello.elf.bin";
        inherit mem;
      };

      mkIncludeosBootStock = includeos.lib.${system}.mkBoot {
        src      = self.packages.${system}.unikernel-stock;
        debugSrc = self.packages.${system}.unikernel-stock;
        kernel   = "hello.elf.bin";
        inherit mem;
      };

      mkLinuxBoot = binary: kvm:
        let
          runner = linux-runner.lib.${system}.mkRunner { inherit kvm mem; };
          name   = if kvm then "linux-kvm" else "linux-tcg";
        in {
          type    = "app";
          program = toString (pkgs.writeShellScript name ''
            exec ${runner}/bin/boot ${binary}/bin/hello_linux
          '');
        };

    in {
      packages.${system} = {
        default = unikernel;
        inherit unikernel unikernel-debug unikernel-mapstack unikernel-stock;
        linux             = linux-binary-patched;
        linux-unpatched   = linux-binary;
        linux-nomapstack  = linux-binary-nomapstack;
      };

      apps.${system} = {
        linux = mkLinuxBoot linux-binary-patched false // {
          kvm = mkLinuxBoot linux-binary-patched true;
          tcg = mkLinuxBoot linux-binary-patched false;
          unpatched = mkLinuxBoot linux-binary false // {
            kvm = mkLinuxBoot linux-binary true;
            tcg = mkLinuxBoot linux-binary false;
          };
          nomapstack = mkLinuxBoot linux-binary-nomapstack false // {
            kvm = mkLinuxBoot linux-binary-nomapstack true;
            tcg = mkLinuxBoot linux-binary-nomapstack false;
          };
        };
        includeos = mkIncludeosBoot;
        includeos-mapstack = mkIncludeosBootMapstack;
        includeos-stock = mkIncludeosBootStock;
      };
    };
}
