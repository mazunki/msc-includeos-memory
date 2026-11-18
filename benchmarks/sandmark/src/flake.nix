{
  description = "Sandmark benchmarks on IncludeOS vs Linux — startup and execution time";

  inputs = {
    nixpkgs.url   = "github:NixOS/nixpkgs/25.05";
    includeos.url = "path:/home/maz/repos/includeos/IncludeOS-thesis";
    includeos.inputs.vmrunner.url = "github:mazunki/vmrunner/flakify";
    linux-runner.url = "github:mazunki/linux-runner";
    # clang 20 + musl oldmalloc for the linux builds
    compiler.url = "path:/home/maz/repos/mazunki/compiler";

    sandmark = { url = "git+file:///home/maz/repos/MagnusS/runtimes/sandmark"; flake = false; };
  };

  outputs = { self, nixpkgs, includeos, linux-runner, compiler, sandmark }:
    let
      system = "x86_64-linux";
      mem    = "4G";

      pkgs = import nixpkgs { inherit system; };

      plotPython = pkgs.python3.withPackages (ps: [ ps.matplotlib ps.numpy ]);

      ocaml = pkgs.pkgsStatic.ocaml-ng.ocamlPackages_5_3.ocaml;

      patchedOcaml = ocaml.overrideAttrs (old: {
        configureFlags = old.configureFlags ++ [
          "--disable-systhreads"
          "--enable-mmap-map-stack"
          "ac_cv_func_sigprocmask=no"
        ];
      });

      mkIncludeos     = includeos.lib.${system}.mkIncludeos;
      iosAttrs        = mkIncludeos {};
      iosAttrsDebug   = mkIncludeos { debug = true; };

      mkLinuxBinaryWith = ocamlFlags: suffix: ocamlPkg: name: mlFile:
        pkgs.runCommand "sandmark-linux-${name}${suffix}" {
          nativeBuildInputs = [ ocamlPkg pkgs.pkgsStatic.buildPackages.binutils ];
          CC = "${clangMusl}/bin/cc";
          src = ./bench;
        } ''
          mkdir -p $out/bin
          cp $src/main_linux.c main_linux.c
          cp $src/test.c test.c
          ${defaultArgvPatch mlFile}
          ${ocamlPkg}/bin/ocamlopt ${ocamlFlags} -c ${mlFile} -o benchmark.cmx
          ${ocamlPkg}/bin/ocamlopt -output-obj ${ocamlFlags} -o benchmarkcode.o benchmark.cmx
          $CC -static \
            -I${ocamlPkg}/lib/ocaml \
            main_linux.c benchmarkcode.o \
            ${ocamlPkg}/lib/ocaml/libasmrun.a \
            -lm -o $out/bin/hello_linux
        '';
      mkLinuxBinary    = mkLinuxBinaryWith "-g" "";
      mkLinuxBinaryNoG = mkLinuxBinaryWith "" "-nog";

      # libasmrun.a is the same on both sides
      compilerPkgs = import compiler.inputs.nixpkgs {
        inherit system;
        overlays = [ (import "${compiler}/toolchain.nix" {}) ];
      };
      clangMusl = compilerPkgs.toolchain.clang_musl;

      mkUnikernel = iosAttrsArg: mlFile:
        (import ./default.nix {
          includeos = iosAttrsArg.includeos;
          benchmarkMl = mlFile;
        }).overrideAttrs (old: {
          buildInputs = old.buildInputs ++ [ iosAttrsArg.chainloader ];
          postPatch = (old.postPatch or "") + defaultArgvPatch mlFile;
          installPhase = ''
            runHook preInstall
            find -mindepth 1 -maxdepth 1 -type f -exec install -v -D -t "$out/" {} \;
            find -mindepth 2 -name '*.elf.bin' -exec install -v -t "$out/" {} \;
            runHook postInstall
          '';
        });

      mkUnikernelNoG = iosAttrsArg: mlFile:
        (mkUnikernel iosAttrsArg mlFile).overrideAttrs {
          postPatch = ''
            sed -i 's/ocamlopt -g /ocamlopt /; s/-output-obj -g /-output-obj /' CMakeLists.txt
            ! grep -n -- ' -g ' CMakeLists.txt
          '';
        };

      # too short without an argument; values from sandmark's own run configs
      defaultArgv = { lazy_primes = "3000"; };
      defaultArgvPatch = mlFile:
        let n = builtins.unsafeDiscardStringContext
                  (pkgs.lib.removeSuffix ".ml" (baseNameOf mlFile));
        in pkgs.lib.optionalString (defaultArgv ? ${n}) (argvPatch defaultArgv.${n});

      # .#<bm>.<set>.kvm, .#<bm>.<set>.includeos.kvm
      argvSets = {
        sm = {
          morestacks   = "1_000";
          alloc        = "200_000";
          sequence_cps = "10000";
          bdd          = "26";
          soli         = "2000";
        };
      };

      # appends arg to test.c's argv
      argvPatch = arg: ''
        sed -i 's|(char\*)"hello", (char\*)NULL|(char*)"hello", (char*)"${arg}", (char*)NULL|' test.c
        grep -qF '(char*)"${arg}", (char*)NULL' test.c
      '';
      mkLinuxBinaryArgv = arg: set: ocamlPkg: name: mlFile:
        (mkLinuxBinaryWith "-g" "-${set}" ocamlPkg name mlFile).overrideAttrs (old: {
          buildCommand = builtins.replaceStrings
            [ "cp $src/test.c test.c\n" ] [ "cp $src/test.c test.c\n${argvPatch arg}" ]
            old.buildCommand;
        });
      mkUnikernelArgv = arg: iosAttrsArg: mlFile:
        (mkUnikernel iosAttrsArg mlFile).overrideAttrs { postPatch = argvPatch arg; };

      mkLinuxBoot = binary: kvm:
        let
          runner  = linux-runner.lib.${system}.mkRunner { inherit kvm mem; };
          appName = if kvm then "linux-kvm" else "linux-tcg";
        in {
          type    = "app";
          program = toString (pkgs.writeShellScript appName ''
            exec ${runner}/bin/boot ${binary}/bin/hello_linux
          '');
        };

      mkIncludeosBootWith = mkUni: mlFile:
        includeos.lib.${system}.mkBoot {
          src      = mkUni iosAttrs mlFile;
          debugSrc = mkUni iosAttrsDebug mlFile;
          kernel   = "hello.elf.bin";
          inherit mem;
        };
      mkIncludeosBoot = mkIncludeosBootWith mkUnikernel;

      iosAttrsTrace = iosAttrs // {
        includeos = iosAttrs.includeos.overrideAttrs (old: {
          NIX_CFLAGS_COMPILE = (old.NIX_CFLAGS_COMPILE or "") + " -DENABLE_STRACE=true -DTRACE_MMAP";
          # avoid strace_print -> futex -> strace_print recursion
          postPatch = (old.postPatch or "") + ''
            sed -i \
              -e 's|^constexpr bool __strace = ENABLE_STRACE;|&\ninline bool __strace_busy = false;|' \
              -e 's|^inline void strace_print(const char\* name, Ret ret, Args&&... args){|&\n  if (__strace_busy) return;\n  __strace_busy = true;|' \
              -e 's|^  __serial_print(str.data(), str.size());|&\n  __strace_busy = false;|' \
              src/musl/common.hpp
            sed -i 's|^  __serial_print1("<WARNING> Stubbed syscall: ");|  if (__strace_busy) return;\n&|' src/musl/stub.hpp
            grep -q __strace_busy src/musl/stub.hpp
            test "$(grep -c __strace_busy src/musl/common.hpp)" = 4
          '';
        });
      };
      mkUnikernelTrace = _: mlFile: mkUnikernel iosAttrsTrace mlFile;

      cpuHost = "host,+rdrand,+rdseed";
      cpuHostJson = pkgs.writeText "vm.json" (builtins.toJSON {
        mem = 4096;
        cpu = { model = "host"; features = [ "rdrand" "rdseed" ]; };
      });
      mkLinuxBootCpuHost = binary:
        let runner = linux-runner.lib.${system}.mkRunner { kvm = true; inherit mem; };
        in {
          type    = "app";
          program = toString (pkgs.writeShellScript "linux-kvm-cpuhost" ''
            exec ${runner}/bin/boot --cpu ${cpuHost} ${binary}/bin/hello_linux
          '');
        };
      mkIncludeosBootCpuHost = mlFile: {
        type    = "app";
        program = toString (pkgs.writeShellScript "includeos-kvm-cpuhost" ''
          exec ${(mkIncludeosBoot mlFile).kvm.program} -j ${cpuHostJson}
        '');
      };

      # single-file, no external packages
      benchmarks = {
        # algorithmic
        almabench       = "${sandmark}/benchmarks/almabench/almabench.ml";
        bdd             = "${sandmark}/benchmarks/bdd/bdd.ml";
        hamming         = "${sandmark}/benchmarks/hamming/hamming.ml";
        soli            = "${sandmark}/benchmarks/soli/soli.ml";
        kb              = "${sandmark}/benchmarks/kb/kb.ml";
        kb_no_exc       = "${sandmark}/benchmarks/kb/kb_no_exc.ml";
        sequence_cps    = "${sandmark}/benchmarks/sequence/sequence_cps.ml";

        # numerical
        dka             = "${sandmark}/benchmarks/numerical-analysis/durand_kerner_aberth.ml";
        crout           = "${sandmark}/benchmarks/numerical-analysis/crout_decomposition.ml";
        qr              = "${sandmark}/benchmarks/numerical-analysis/qr_decomposition.ml";

        # recursion (rec_eff_* need pre-5 syntax)
        rec_seq_fib     = "${sandmark}/benchmarks/multicore-effects/rec_seq_fib.ml";
        rec_seq_tak     = "${sandmark}/benchmarks/multicore-effects/rec_seq_tak.ml";
        rec_seq_ack     = "${sandmark}/benchmarks/multicore-effects/rec_seq_ack.ml";
        rec_seq_motzkin = "${sandmark}/benchmarks/multicore-effects/rec_seq_motzkin.ml";
        rec_seq_sudan   = "${sandmark}/benchmarks/multicore-effects/rec_seq_sudan.ml";

        # allocation
        alloc           = "${sandmark}/benchmarks/simple-tests/alloc.ml";
        morestacks      = "${sandmark}/benchmarks/simple-tests/morestacks.ml";
        lazy_primes     = "${sandmark}/benchmarks/simple-tests/lazy_primes.ml";
        # weak_htbl: needs the removed Pervasives module
      };

      mkBenchmarkApps = name: mlFile:
        let
          linuxBin   = mkLinuxBinary patchedOcaml name mlFile;
          linuxUnpat = mkLinuxBinary ocaml         name mlFile;
          linuxNoG   = mkLinuxBinaryNoG patchedOcaml name mlFile;        in mkLinuxBoot linuxBin false // {
          kvm       = mkLinuxBoot linuxBin true;
          # .#<bm>.linux[.kvm]
          linux     = mkLinuxBoot linuxBin false // {
            kvm = mkLinuxBoot linuxBin true;
          };
          unpatched = mkLinuxBoot linuxUnpat false // {
            kvm = mkLinuxBoot linuxUnpat true;
          };
          includeos = mkIncludeosBoot mlFile;
          # .#<bm>.nog.kvm, .#<bm>.nog.includeos.kvm
          nog = mkLinuxBoot linuxNoG false // {
            kvm       = mkLinuxBoot linuxNoG true;
            includeos = mkIncludeosBootWith mkUnikernelNoG mlFile;
          };
          # .#<bm>.trace.includeos.kvm
          trace = { includeos = mkIncludeosBootWith mkUnikernelTrace mlFile; };
          cpuhost = {
            kvm       = mkLinuxBootCpuHost linuxBin;
            includeos = { kvm = mkIncludeosBootCpuHost mlFile; };
          };        } // pkgs.lib.mapAttrs (set: args:
          let bin = mkLinuxBinaryArgv args.${name} set patchedOcaml name mlFile;
          in mkLinuxBoot bin false // {
            kvm       = mkLinuxBoot bin true;
            includeos = mkIncludeosBootWith (mkUnikernelArgv args.${name}) mlFile;
          }) (pkgs.lib.filterAttrs (_: args: args ? ${name}) argvSets);

    in {
      packages.${system} =
        pkgs.lib.foldlAttrs (acc: name: mlFile: acc // {
          "${name}-linux"           = mkLinuxBinary patchedOcaml name mlFile;
          "${name}-linux-unpatched" = mkLinuxBinary ocaml         name mlFile;
          "${name}-unikernel"       = mkUnikernel iosAttrs mlFile;
          "${name}-linux-nog"       = mkLinuxBinaryNoG patchedOcaml name mlFile;
          "${name}-unikernel-nog"   = mkUnikernelNoG iosAttrs mlFile;
          "${name}-unikernel-trace" = mkUnikernelTrace iosAttrs mlFile;        } // pkgs.lib.concatMapAttrs (set: args: pkgs.lib.optionalAttrs (args ? ${name}) {
          "${name}-linux-${set}"     = mkLinuxBinaryArgv args.${name} set patchedOcaml name mlFile;
          "${name}-unikernel-${set}" = mkUnikernelArgv args.${name} iosAttrs mlFile;
        }) argvSets) {
          # nix shell .#perf, then BENCH_PERF=stat|kvm
          perf = pkgs.linuxPackages.perf;
        } benchmarks;

      apps.${system} = pkgs.lib.mapAttrs mkBenchmarkApps benchmarks // {
        plot = {
          type = "app";
          program = toString (pkgs.writeShellScript "sandmark-plot" ''
            exec ${plotPython}/bin/python3 ${./bench.py} plot "$@"
          '');
        };
      };
    };
}
