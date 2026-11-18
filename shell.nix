{
  pkgs ? import (fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/25.05.tar.gz";
    sha256 = "1915r28xc4znrh2vf4rrjnxldw2imysz819gzhk9qlrkqanmfsxd";
  }) { },
}:

pkgs.mkShell {
  packages = with pkgs; [
    nil
    nixd
    nixfmt-rfc-style
    shellcheck
    clang-tools
    neocmakelsp
    python3
  ];
}
