# SPDX-License-Identifier: MIT OR Apache-2.0
# NixOS installation and portal integration for Ciri. Home configuration is
# deliberately separate in homeManagerModules.ciri.
{ self, descriptorFor }:
{ lib, config, options, pkgs, ... }:
let
  cfg = config.programs.ciri;
in
{
  options.programs.ciri = {
    enable = lib.mkEnableOption "the complete Ciri compositor runtime product";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.ciri;
      defaultText = lib.literalExpression
        "inputs.nixciri.packages.\${pkgs.stdenv.hostPlatform.system}.ciri";
      description = "The pinned Ciri runtime package.";
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [
        cfg.package
        pkgs.xdg-desktop-portal-gnome
        pkgs.xdg-desktop-portal-gtk
        pkgs.xwayland-satellite
      ];

      services.displayManager.sessionPackages = [ cfg.package ];

      xdg.portal = {
        enable = true;
        extraPortals = [
          pkgs.xdg-desktop-portal-gnome
          pkgs.xdg-desktop-portal-gtk
        ];
        configPackages = [ cfg.package ];
      };
    }

    # Ciri's launch mechanisms are compositor integration data, not
    # nixdesktop defaults. Standalone use remains a valid system installer.
    (lib.optionalAttrs (lib.hasAttrByPath [ "nixdesktop" "launcher" "compositors" ] options) {
      nixdesktop.launcher.compositors.ciri = descriptorFor cfg.package;
    })
  ]);
}
