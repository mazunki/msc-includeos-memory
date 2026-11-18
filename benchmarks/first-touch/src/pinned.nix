# nixpkgs 25.05, without the musl-unpatched overlay: replacing musl globally
# breaks the musl bootstrap (the unpatched build is static-only, see musl-unpatched.nix).
import (
  builtins.fetchTarball {
    url = "https://github.com/NixOS/nixpkgs/archive/refs/tags/25.05.tar.gz";
    sha256 = "1915r28xc4znrh2vf4rrjnxldw2imysz819gzhk9qlrkqanmfsxd";
  }
) {}
