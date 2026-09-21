# SPDX-License-Identifier: MIT OR Apache-2.0
# Arch/CachyOS integration for the complete Ciri product.
#
# The compositor comes from the pinned corbet-labs/ciri input. Arch supplies
# only the external desktop services Ciri expects. nixdesktop owns process
# seating and device fencing; this module contributes one compositor
# descriptor and no private session values.
{ self, descriptorFor }:
{ lib, config, pkgs, ... }:
let
  cfg = config.nixciri;
  defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.ciri;
in
{
  options.nixciri = {
    enable = lib.mkEnableOption "the complete Ciri compositor runtime product";

    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      defaultText = lib.literalExpression
        "inputs.nixciri.packages.\${pkgs.stdenv.hostPlatform.system}.ciri";
      description = ''
        The exact Ciri package registered with nixdesktop and installed by
        store path. It is not rebuilt independently by pacman or the AUR.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    nixdesktop.launcher.compositors.ciri = descriptorFor cfg.package;

    # Keep the seated unit on its exact package path and expose the same Ciri
    # binary to operators for `ciri msg` and validation. There is no parallel
    # distro package and therefore no shadow command to retain.
    environment.systemPackages = [ cfg.package ];

    nixarch.packages.pacman = [
      "xdg-desktop-portal-gnome"
      "xdg-desktop-portal-gtk"
      "xwayland-satellite"
    ];

    environment.etc."xdg-desktop-portal/ciri-portals.conf" = {
      # system-manager otherwise leaves an occupied destination untouched.
      replaceExisting = true;
      text = ''
        [preferred]
        default=gnome;gtk;
        org.freedesktop.impl.portal.Access=gtk
        org.freedesktop.impl.portal.FileChooser=gtk
        org.freedesktop.impl.portal.Notification=gtk
      '';
    };
  };
}
