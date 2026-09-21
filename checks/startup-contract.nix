# SPDX-License-Identifier: MIT OR Apache-2.0
# Evaluates home/ciri.nix for real, and asserts the `nixdesktop.startup` seam works BOTH ways.
#
# WHY THIS FILE EXISTS AT ALL: `nix flake check` does not evaluate `homeManagerModules`. It reports
# them as "unchecked" and moves on, so a green check here previously covered nothing this repo
# actually ships -- the module could fail to evaluate, or render the wrong thing, and CI would
# still pass.
#
# The stub below is a deliberately minimal stand-in for the home-manager options this module
# writes to. It is NOT an attempt to reimplement home-manager: the point is to evaluate THIS
# module's own logic, and a full home-manager instantiation would add a large dependency for no
# extra coverage of the thing under test.
#
# `ciriModule` arrives here ALREADY partially applied (flake.nix closes `home/ciri.nix` over the
# real, locked `nixhost.lib.probeFact`/`collectProbes` before this check ever runs, the same shape
# nixscroll's own checks/startup-contract.nix uses for `scrollModule`) -- this file never reaches
# for the raw `../home/ciri.nix` path itself, which would fail outright now that the module takes
# `{ probeFact, collectProbes }:` as its outer argument.
{ pkgs, lib ? pkgs.lib, ciriModule }:
let
  stubs = { lib, ... }: {
    options = {
      xdg.configFile = lib.mkOption {
        type = lib.types.attrsOf (lib.types.attrsOf lib.types.anything);
        default = { };
      };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      home.file = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.user = lib.mkOption { type = lib.types.anything; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.anything; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  # The neutral contract, declared the way nixdesktop declares it, and populated the way a
  # nixdesktop component populates it. Deliberately includes an entry with a flag: contract
  # entries are shell command strings, so anything rendered through niri's argv-taking
  # `spawn-at-startup` rather than `spawn-sh-at-startup` would mis-handle this one.
  contract = { lib, ... }: {
    options.nixdesktop = {
      startup = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
      };
      session.readinessBridge = {
        enable = lib.mkOption { type = lib.types.bool; default = false; };
        serviceName = lib.mkOption { type = lib.types.str; default = ""; };
        socketEnvironment = lib.mkOption { type = lib.types.str; default = ""; };
      };
    };
    config.nixdesktop.startup = [ "desktop-component --daemon" "some-agent --flag" ];
  };

  evaluate = extra: (lib.evalModules {
    modules = [ stubs ciriModule { programs.ciri.enable = true; } ] ++ extra;
    specialArgs = { inherit pkgs; };
  }).config;

  withContractConfig = evaluate [ contract ];
  withoutContractConfig = evaluate [ ];
  withContract = withContractConfig.xdg.configFile."ciri/config.kdl".text;
  withoutContract = withoutContractConfig.xdg.configFile."ciri/config.kdl".text;

  has = haystack: needle: lib.hasInfix needle haystack;

  results = {
    # POSITIVE — contract entries reach the KDL, in Ciri's shell-taking spawn form.
    "contract entry renders as spawn-sh-at-startup" =
      has withContract ''spawn-sh-at-startup "desktop-component --daemon"'';
    "a contract entry carrying a flag survives intact" =
      has withContract ''spawn-sh-at-startup "some-agent --flag"'';

    # NEGATIVE — with NO nixdesktop module in scope at all, this module must still evaluate (that
    # `withoutContract` is a string at all proves it) and must render none of the contract.
    "evaluates and renders nothing extra when nixdesktop is absent" =
      !(has withoutContract "desktop-component");

    "composition selects Ciri's generic readiness bridge without a compatibility alias" =
      withContractConfig.nixdesktop.session.readinessBridge == {
        enable = true;
        serviceName = "ciri";
        socketEnvironment = "CIRI_SOCKET";
      };

    # POLICY ABSENCE — the integration must not invent desktop furniture or private binds.
    "the public module ships no keybindings" = !(has withoutContract "binds {");
    "the public module does not invent lock, OSD, or polkit commands" =
      lib.all (term: !(has withoutContract term)) [ "swaylock" "swayosd" "polkit" ];
    "the public module ships no input, visual, workspace, or application policy" =
      lib.all (term: !(has withoutContract term)) [
        "input {"
        "layout {"
        "workspace \""
        "window-rule {"
        "screenshot-path"
      ];

    # NON-VACUITY — without this, an empty render would make every hasInfix check above pass
    # trivially and the whole file would be a very confident no-op.
    "both renders are real, non-empty configs" =
      lib.stringLength withoutContract > 200 && lib.stringLength withContract > 200;
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
# `pkgs.emptyFile`, NOT `pkgs.runCommand ... "touch $out"`: a `runCommand` marker's output path is
# SYSTEM-DEPENDENT, so evaluating this check for a foreign arch under `--all-systems` on x86_64
# turns "unchecked" into a real foreign-arch BUILD, which fails "platform mismatch" rather than
# substituting. `emptyFile` is fixed-output content-addressed and substitutes everywhere -- the
# same fix nixdesktop already applied to its own check markers.
then pkgs.emptyFile
else throw ''
  nixciri: the nixdesktop.startup seam is broken. Failing assertions:
  ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
''
