{
  description = "Syscall latency benchmark for Linux and IncludeOS";

  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/25.05";
    includeos.url    = "github:mazunki/IncludeOS/dev";
    includeos.inputs.vmrunner.url = "github:mazunki/vmrunner/dev";
    linux-runner.url = "github:mazunki/linux-runner";
  };

  outputs = { self, nixpkgs, includeos, linux-runner }:
    let
      system = "x86_64-linux";
      mem = "16G";

      mkUnikernel     = includeos.lib.${system}.mkUnikernel;
      mkLinuxBoot     = linux-runner.lib.${system}.mkBoot { src ="./"; inherit mem; };
      mkIncludeosBoot = includeos.lib.${system}.mkBoot {
        src      = self.packages.${system}.unikernel;
        debugSrc = self.packages.${system}.unikernel-debug;
        kernel   = "syscall_latency.elf.bin";
        inherit mem;
      };

      unikernel       = mkUnikernel { unikernel = ./.; };
      unikernel-debug = mkUnikernel { unikernel = ./.; debug = true; };
    in {
      packages.${system} = { default = unikernel; inherit unikernel unikernel-debug; };

      apps.${system} = {
        linux     = mkLinuxBoot;
        includeos = mkIncludeosBoot;
      };
    };
}
