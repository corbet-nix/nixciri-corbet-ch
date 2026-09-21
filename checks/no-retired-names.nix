# SPDX-License-Identifier: MIT OR Apache-2.0
{ pkgs, src }:

pkgs.runCommand "nixciri-no-retired-names"
{
  inherit src;
  nativeBuildInputs = [ pkgs.ripgrep ];
}
  ''
    retired='nixniri|home/niri[.]nix|[.]config/niri|niri/config[.]kdl|homeManagerModules[.]niri|NIRI_SOCKET|niri[.]service'

    if rg -n --hidden \
      --glob '!**/checks/no-retired-names.nix' \
      --glob '!flake.lock' \
      "$retired" "$src"; then
      echo "FAIL: a retired public compositor name remains in nixciri."
      exit 1
    fi

    touch "$out"
  ''
