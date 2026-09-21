# SPDX-License-Identifier: MIT OR Apache-2.0
# Evaluate the NixOS integration with and without nixdesktop's optional
# registry. The product must install standalone and register the exact same
# complete Ciri descriptor when the neutral launcher is composed.
{ pkgs, lib ? pkgs.lib, nixosModule }:
let
  fakeCiri = pkgs.writeShellScriptBin "ciri" "exit 0";

  baseStubs = { lib, ... }: {
    options = {
      environment.systemPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
      services.displayManager.sessionPackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
      };
      xdg.portal = lib.mkOption { type = lib.types.anything; default = { }; };
    };
  };

  desktopStub = { lib, ... }: {
    options.nixdesktop.launcher.compositors = lib.mkOption {
      type = lib.types.attrsOf lib.types.anything;
      default = { };
    };
  };

  evaluate = modules: (lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [ baseStubs nixosModule ] ++ modules ++ [{
      programs.ciri = {
        enable = true;
        package = fakeCiri;
      };
    }];
  }).config;

  standalone = evaluate [ ];
  composed = evaluate [ desktopStub ];
  descriptor = composed.nixdesktop.launcher.compositors.ciri;

  results = {
    "standalone use installs the selected runtime without requiring nixdesktop" =
      lib.elem fakeCiri standalone.environment.systemPackages
      && standalone.services.displayManager.sessionPackages == [ fakeCiri ];
    "composition registers the complete neutral-to-Ciri translation" =
      toString descriptor.package == toString fakeCiri
      && descriptor.command == "ciri --session"
      && descriptor.deviceEnvironment == [ ]
      && descriptor.rendererEnvironment.software.LIBGL_ALWAYS_SOFTWARE == "1"
      && descriptor.headlessEnvironment == { }
      && !descriptor.supportsHeadless
      && !descriptor.supportsVirtualOutputs
      && descriptor.supportsNotify
      && descriptor.currentDesktop == "ciri";
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
then pkgs.emptyFile
else throw ''
  nixciri: the NixOS integration is broken. Failing assertions:
  ${lib.concatMapStringsSep "\n" (failure: "  - ${failure}") failed}
''
