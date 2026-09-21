# SPDX-License-Identifier: MIT OR Apache-2.0
# Evaluate the Arch/system-manager product boundary without requiring
# system-manager itself. The stubs cover only options written by the module.
{ pkgs, lib ? pkgs.lib, systemManagerModule }:
let
  fakeCiri = pkgs.writeShellScriptBin "ciri" "exit 0";

  stubs = { lib, ... }: {
    options = {
      nixarch.packages = {
        pacman = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
        aur = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
      };
      nixdesktop.launcher.compositors = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
      };
      environment.systemPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
      environment.etc = lib.mkOption {
        default = { };
        type = lib.types.attrsOf (lib.types.submodule {
          options = {
            text = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
            replaceExisting = lib.mkOption { type = lib.types.bool; default = false; };
          };
        });
      };
    };
  };

  evaluate = extraConfig: (lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [ stubs systemManagerModule extraConfig ];
  }).config;

  enabled = evaluate {
    nixciri = {
      enable = true;
      package = fakeCiri;
    };
  };
  disabled = evaluate { };
  descriptor = enabled.nixdesktop.launcher.compositors.ciri;
  portal = enabled.environment.etc."xdg-desktop-portal/ciri-portals.conf";

  results = {
    "the selected derivation and Ciri argv form one descriptor" =
      toString descriptor.package == toString fakeCiri
      && descriptor.command == "ciri --session";
    "the Ciri operator command is on the system path" =
      enabled.environment.systemPackages == [ fakeCiri ];
    "the descriptor carries only Ciri mechanisms" =
      descriptor.deviceEnvironment == [ ]
      && descriptor.rendererEnvironment.auto == { }
      && descriptor.rendererEnvironment.hardware == { }
      && descriptor.rendererEnvironment.software.LIBGL_ALWAYS_SOFTWARE == "1"
      && descriptor.headlessEnvironment == { }
      && !descriptor.supportsHeadless
      && !descriptor.supportsVirtualOutputs
      && descriptor.supportsNotify
      && descriptor.currentDesktop == "ciri";
    "all Arch companions are official packages" =
      enabled.nixarch.packages.pacman == [
        "xdg-desktop-portal-gnome"
        "xdg-desktop-portal-gtk"
        "xwayland-satellite"
      ]
      && enabled.nixarch.packages.aur == [ ];
    "the portal route is desktop-specific and replace-safe" =
      lib.attrNames enabled.environment.etc == [ "xdg-desktop-portal/ciri-portals.conf" ]
      && portal.replaceExisting
      && lib.hasInfix "default=gnome;gtk;" portal.text;
    "disabling nixciri removes its complete public integration" =
      disabled.nixarch.packages.pacman == [ ]
      && disabled.nixarch.packages.aur == [ ]
      && disabled.nixdesktop.launcher.compositors == { }
      && disabled.environment.systemPackages == [ ]
      && disabled.environment.etc == { };
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.emptyFile
else throw ''
  nixciri: the Arch integration is broken. Failing assertions:
  ${lib.concatMapStringsSep "\n" (failure: "  - ${failure}") failed}
''
