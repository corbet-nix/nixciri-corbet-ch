# SPDX-License-Identifier: MIT OR Apache-2.0
# Evaluates home/ciri.nix's structured-output/layout/session seam for real: this is the part of
# this session's work that replaced a single raw-KDL string with something a registry can key on
# and a build can assert about, so it is the part with the most SILENT failure modes to close.
#
# Mirrors checks/startup-contract.nix's own doctrine (a minimal home-manager stub, not a full
# instantiation) and nixscroll's checks/startup-contract.nix fact-wiring group (proving
# lib.probeFact's three states -- absent/resolved/unresolved -- through the REAL module, not just
# against nixhost's own lib/facts.nix tests). `ciriModule` arrives here ALREADY partially applied
# over the real, locked `nixhost.lib.probeFact`/`collectProbes` (see flake.nix) -- this file never
# reaches for the raw `../home/ciri.nix` path.
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

  # ── Minimal stand-ins for nixdisplay and nixdesktop producer modules ────────────────────────
  # Deliberately narrow -- just the fields home/ciri.nix's own translator actually reads -- not an
  # attempt to reimplement nixdisplay's layout/monitor modules or nixdesktop's session module
  # assertions, e.g. "monitor slug must exist", are that repo's checks to own, not this one's).

  outputEntrySubmodule = lib.types.submodule {
    options = {
      monitor = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      connector = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      match = lib.mkOption { type = lib.types.enum [ "identity" "connector" ]; default = "identity"; };
      enable = lib.mkOption { type = lib.types.bool; default = true; };
      mode = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      modeline = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
      scale = lib.mkOption { type = lib.types.nullOr lib.types.numbers.positive; default = null; };
      position = lib.mkOption {
        type = lib.types.nullOr (lib.types.submodule {
          options = {
            x = lib.mkOption { type = lib.types.int; };
            y = lib.mkOption { type = lib.types.int; };
          };
        });
        default = null;
      };
      transform = lib.mkOption {
        type = lib.types.enum [ "normal" "90" "180" "270" "flipped" "flipped-90" "flipped-180" "flipped-270" ];
        default = "normal";
      };
    };
  };

  layoutsFixture = { lib, ... }: {
    options.nixdisplay.layouts = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options.outputs = lib.mkOption { type = lib.types.listOf outputEntrySubmodule; default = [ ]; };
      });
      default = { };
    };
    # One identity-matched entry (the panel this session's whole translation exists for) and one
    # connector-matched, DISABLED entry (the laptop panel, turned off while docked) -- covering
    # both matcher shapes and the `off` flag in a single fixture.
    config.nixdisplay.layouts.docked.outputs = [
      {
        monitor = "u4323qe";
        match = "identity";
        mode = "3840x2160@60";
        scale = 1.5;
        position = { x = 0; y = 0; };
        transform = "90"; # chosen precisely because sway/scroll would have to invert this; niri must not.
      }
      {
        connector = "eDP-1";
        match = "connector";
        enable = false;
      }
    ];
  };

  monitorsFixture = { lib, ... }: {
    options.nixdisplay.monitors = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          identifier = lib.mkOption { type = lib.types.str; };
          aliases = lib.mkOption {
            type = lib.types.listOf (lib.types.submodule { options.identifier = lib.mkOption { type = lib.types.str; }; });
            default = [ ];
          };
        };
      });
      default = { };
    };
    # A monitor with one alias -- the KVM-fed panel case nixdisplay documents, where the
    # same physical panel presents a different EDID identity through a second input.
    config.nixdisplay.monitors.u4323qe = {
      identifier = "Dell Inc. DELL U4323QE 9BQR2P3";
      aliases = [ { identifier = "Dell Inc. DELL U4323QE 9BQR2P3 ALT"; } ];
    };
  };

  sessionsFixture = { lib, ... }: {
    options.nixdesktop.sessions = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          permittedDevices = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
          deniedDevices = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
        };
      });
      default = { };
    };
    config.nixdesktop.sessions = {
      primary = {
        permittedDevices = [ "ast" ];
        deniedDevices = [ "amd" "evdi" ];
      };
      # Two more, for the nixgpu-resolution failure paths below: one naming a device the
      # inventory does not declare AT ALL, one naming a device the inventory HAS but with no
      # `address` -- the two ways a name out of permittedDevices/deniedDevices can fail to
      # resolve to a stable path.
      orphan-device.permittedDevices = [ "ghost" ];
      no-address-device.permittedDevices = [ "unaddressed" ];
    };
  };

  # Minimal stand-in for nixgpu's `stableDevicePaths.devices` -- just the three fields
  # home/ciri.nix's own `devicePathFor` reads (`address`, `cardPath`, `renderPath`), not nixgpu's
  # own vendor/pciId/bus schema or its `cardPath`/`renderPath` THROW-on-no-address derivation
  # (that behaviour is nixgpu's own to test; this file only has to prove nixciri reads the three
  # fields correctly and asserts sanely when they are missing or incomplete).
  #
  # "ast" (a BMC framebuffer -- `DRIVER_GEM | DRIVER_MODESET` only, no render node, ever) and
  # "evdi" (a platform device -- `DRIVER_RENDER` never set, by driver fact, regardless of
  # address) both have `renderPath = null`, proving the cardPath fallback; "amd" (a real GPU) has
  # both, proving the renderPath preference. "unaddressed" exists in the inventory but declares
  # no `address` -- the one state nixgpu's own cardPath/renderPath can never resolve from.
  stableDevicePathsFixture = { lib, ... }: {
    options.nixgpu.stableDevicePaths.devices = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule {
        options = {
          address = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
          cardPath = lib.mkOption { type = lib.types.str; };
          renderPath = lib.mkOption { type = lib.types.nullOr lib.types.str; default = null; };
        };
      });
      default = { };
    };
    config.nixgpu.stableDevicePaths.devices = {
      ast = {
        address = "0000:00:02.0";
        cardPath = "/dev/dri/by-path/pci-0000:00:02.0-card";
        renderPath = null;
      };
      amd = {
        address = "0000:0a:00.0";
        cardPath = "/dev/dri/by-path/pci-0000:0a:00.0-card";
        renderPath = "/dev/dri/by-path/pci-0000:0a:00.0-render";
      };
      evdi = {
        address = "evdi.0";
        cardPath = "/dev/dri/by-path/platform-evdi.0-card";
        renderPath = null;
      };
      unaddressed = {
        address = null;
        # Never actually reached in a passing config -- the assertion under test fires on
        # `address == null` alone, before anything would force this field.
        cardPath = "/dev/dri/by-path/pci-0000:ff:00.0-card";
        renderPath = null;
      };
    };
  };

  # A fake, minimally-versioned Ciri package for the version-assertion tests below.
  # `pkgs.emptyFile` is already a derivation; `//` only adds the one
  # attribute `cfg.package.version` actually reads.
  fakeCiriPackage = version: pkgs.emptyFile // { inherit version; };

  # The decoy: nixdisplay is composed through an unrelated leaf, but its layouts module is not.
  # This is the unresolved state probeFact must distinguish from total namespace absence.
  unrelatedNixdisplay = { lib, ... }: {
    options.nixdisplay.roles = lib.mkOption { type = lib.types.attrsOf lib.types.bool; default = { }; };
    config.nixdisplay.roles = { };
  };

  evalCiri = extra: (lib.evalModules {
    modules = [ stubs ciriModule ] ++ extra;
    specialArgs = { inherit pkgs; };
  }).config;

  render = extra: (evalCiri extra).xdg.configFile."ciri/config.kdl".text;
  warningsOf = extra: (evalCiri extra).warnings;
  assertionsOf = extra: (evalCiri extra).assertions;

  has = haystack: needle: lib.hasInfix needle haystack;
  failingMessages = assertions: map (a: a.message) (lib.filter (a: !a.assertion) assertions);

  # Line-based lookup (same shape as nixscroll's own `lineIndexOf`): robust against this file's
  # own indentation choices, which a raw multi-line `hasInfix` would otherwise couple this check to.
  lines = text: lib.splitString "\n" text;
  trimmed = s: lib.strings.trim s;
  indexOfLine = text: needle:
    let
      ls = lines text;
      hits = lib.filter (i: has (builtins.elemAt ls i) needle) (lib.range 0 (builtins.length ls - 1));
    in
    if hits == [ ] then null else builtins.head hits;
  lineAt = text: i: builtins.elemAt (lines text) i;

  base = { programs.ciri.enable = true; };

  # ── manual `outputs`: block shape, quoting, modeline requoting, transform, off ────────────────
  manualRendered = render [
    base
    {
      programs.ciri.outputs = {
        "Dell Inc. DELL U4323QE 9BQR2P3" = {
          mode = "3840x2160@60";
          modeline = "148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync";
          scale = 1.5;
          position = { x = 0; y = 0; };
          transform = "flipped-270";
        };
        "Off Panel" = { enable = false; };
      };
    }
  ];

  # Every transform value niri's own KDL enum accepts, rendered one at a time -- proving
  # passthrough for ALL of them, not just whichever one the fixtures above happen to pick.
  transformValues = [ "normal" "90" "180" "270" "flipped" "flipped-90" "flipped-180" "flipped-270" ];
  transformRendered = t: render [ base { programs.ciri.outputs."DP-1" = { transform = t; }; } ];

  # ── layout translation: alias variants, connector passthrough, transform passthrough ─────────
  layoutRendered = render [ base layoutsFixture monitorsFixture { programs.ciri.layout = "docked"; } ];

  # ── session translation: denylist + primary render device, resolved to REAL stable paths ──────
  sessionRendered = render [ base sessionsFixture stableDevicePathsFixture { programs.ciri.session = "primary"; } ];
  sessionWarnings = warningsOf [ base sessionsFixture stableDevicePathsFixture { programs.ciri.session = "primary"; } ];

  # ── fact-wiring: an unresolvable name is a hard failure, never a silent no-op ─────────────────
  unknownLayoutAssertions = assertionsOf [ base layoutsFixture { programs.ciri.layout = "nonexistent"; } ];
  unknownSessionAssertions = assertionsOf [ base sessionsFixture { programs.ciri.session = "nonexistent"; } ];

  # ── fact-wiring: the niri-version gate on the volatile `debug` namespace ───────────────────────
  packageMissingAssertions =
    assertionsOf [ base sessionsFixture stableDevicePathsFixture { programs.ciri.session = "primary"; } ];
  packageTooOldAssertions = assertionsOf [
    base sessionsFixture stableDevicePathsFixture
    { programs.ciri.session = "primary"; programs.ciri.package = fakeCiriPackage "24.01"; }
  ];
  packageOkAssertions = assertionsOf [
    base sessionsFixture stableDevicePathsFixture
    { programs.ciri.session = "primary"; programs.ciri.package = fakeCiriPackage "26.04"; }
  ];

  # ── fact-wiring: a device name that cannot resolve to a stable path is a hard failure too ─────
  orphanDeviceAssertions = assertionsOf [
    base sessionsFixture stableDevicePathsFixture
    { programs.ciri.session = "orphan-device"; programs.ciri.package = fakeCiriPackage "26.04"; }
  ];
  noAddressAssertions = assertionsOf [
    base sessionsFixture stableDevicePathsFixture
    { programs.ciri.session = "no-address-device"; programs.ciri.package = fakeCiriPackage "26.04"; }
  ];

  # ── fact-wiring: nixdisplay composed (via an unrelated leaf), layouts genuinely never
  # imported -- must warn AND fail, because the host explicitly asked for a layout it does not
  # have. This is state (c) from nixhost's own lib/facts.nix, proven through THIS module.
  renamedWarnings = warningsOf [ base unrelatedNixdisplay { programs.ciri.layout = "docked"; } ];
  renamedAssertions = assertionsOf [ base unrelatedNixdisplay { programs.ciri.layout = "docked"; } ];

  # ── the quiet baseline: nothing composed, nothing named -- silent and correct ─────────────────
  quietRendered = render [ base ];
  quietWarnings = warningsOf [ base ];
  quietAssertions = assertionsOf [ base ];

  # ── the "off" block, checked line-by-line so this check does not couple itself to
  # renderOutputBlock's own indentation choices ──────────────────────────────────────────────────
  offBlockOk =
    let
      i = indexOfLine manualRendered ''output "Off Panel" {'';
    in
    i != null
    && trimmed (lineAt manualRendered (i + 1)) == "off"
    && trimmed (lineAt manualRendered (i + 2)) == "}";

  connectorOffBlockOk =
    let
      i = indexOfLine layoutRendered ''output "eDP-1" {'';
    in
    i != null
    && trimmed (lineAt layoutRendered (i + 1)) == "off"
    && trimmed (lineAt layoutRendered (i + 2)) == "}";

  results = {
    # ── a structured output renders valid-looking KDL (block shape, fields reach the file) ─────
    "an identity key containing spaces is quoted as ONE KDL string" =
      has manualRendered ''output "Dell Inc. DELL U4323QE 9BQR2P3" {'';
    "a manual entry's mode/scale/position all reach the block" =
      has manualRendered ''mode "3840x2160@60"''
      && has manualRendered "scale 1.5"
      && has manualRendered "position x=0 y=0";
    "a disabled output renders bare `off` and nothing else in its block" = offBlockOk;

    # ── modeline: the 9 timing numbers pass through, trailing sync flags get requoted for niri ─
    "modeline's nine timing numbers pass through unquoted and in order" =
      has manualRendered "modeline 148.50 1920 2008 2052 2200 1080 1084 1089 1125";
    "modeline's trailing sync flags are individually double-quoted for niri" =
      has manualRendered ''"+hsync" "+vsync"'';

    # ── transform passes through UNCHANGED for every accepted value -- no inversion table ──────
    "transform passes through unmodified for every accepted value" =
      lib.all (t: has (transformRendered t) ''transform "${t}"'') transformValues;

    # ── layout translation: one block per alias identity variant ──────────────────────────────
    "the monitor's own identity gets a block" =
      has layoutRendered ''output "Dell Inc. DELL U4323QE 9BQR2P3" {'';
    "every alias identity ALSO gets its own block, not just the primary" =
      has layoutRendered ''output "Dell Inc. DELL U4323QE 9BQR2P3 ALT" {'';
    "both identity variants carry the SAME resolved mode" =
      lib.length (lib.filter (l: has l ''mode "3840x2160@60"'') (lines layoutRendered)) >= 2;
    "a layout's transform passes through unchanged too (Ciri is counter-clockwise already)" =
      has layoutRendered ''transform "90"'';
    "a connector-matched layout entry renders exactly once, by its connector name" =
      has layoutRendered ''output "eDP-1" {'';
    "the disabled connector-matched entry renders bare `off`" = connectorOffBlockOk;

    # ── session translation: the denylist and the primary render device, as REAL stable paths ──
    # niri reads config.kdl straight off disk (no launcher step resolves anything afterwards),
    # so a bare device NAME here would restrict nothing at all -- see home/ciri.nix's own
    # `deviceDebugLines` comment. These are the tests that would have caught that.
    "the primary permitted device becomes render-drm-device, as its real stable path" =
      has sessionRendered ''render-drm-device "/dev/dri/by-path/pci-0000:00:02.0-card"'';
    "a denied device WITH a render node prefers its render path" =
      has sessionRendered ''ignore-drm-device "/dev/dri/by-path/pci-0000:0a:00.0-render"'';
    "a denied device with NO render node (evdi) falls back to its card path" =
      has sessionRendered ''ignore-drm-device "/dev/dri/by-path/platform-evdi.0-card"'';
    # Checked against the ACTUAL directive lines only, not the whole rendered text -- this
    # module's own explanatory comment right above the debug block legitimately contains the
    # substring "/dev/dri" too, which a whole-text search would pass trivially either way.
    "the debug block's device values are stable /dev/dri/by-path paths, never bare device names" =
      let
        deviceLines = lib.filter
          (l: has l "render-drm-device" || has l "ignore-drm-device")
          (lines sessionRendered);
      in
      deviceLines != [ ] && lib.all (l: has l "/dev/dri/by-path/") deviceLines;
    "using a session renders a debug-namespace volatility warning" =
      lib.any (w: has w "debug") sessionWarnings;

    # ── fact-wiring: an unresolvable name is a hard build failure, never a silent no-op ────────
    "naming an undeclared layout fails the build, naming it" =
      lib.any (m: has m ''"nonexistent"'' && has m "programs.ciri.layout")
        (failingMessages unknownLayoutAssertions);
    "naming an undeclared session fails the build, naming it" =
      lib.any (m: has m ''"nonexistent"'' && has m "programs.ciri.session")
        (failingMessages unknownSessionAssertions);

    # ── fact-wiring: the volatile `debug` namespace is pinned to a real niri VERSION ───────────
    "a session with no package set fails the build, naming programs.ciri.package" =
      lib.any (m: has m "programs.ciri.package") (failingMessages packageMissingAssertions);
    "a session on a Ciri older than 25.11 fails the build, naming both versions" =
      lib.any (m: has m "24.01" && has m "25.11") (failingMessages packageTooOldAssertions);
    "a session on Ciri >= 25.11 with a fully-resolved device set passes every assertion" =
      lib.all (a: a.assertion) packageOkAssertions;

    # ── fact-wiring: a device name that cannot resolve to a stable path is a hard failure too ──
    "a device absent from nixgpu.stableDevicePaths fails the build, naming the device" =
      lib.any (m: has m ''"ghost"'' && has m "nixgpu.stableDevicePaths")
        (failingMessages orphanDeviceAssertions);
    "a device declaring no `address` fails the build, naming it" =
      lib.any (m: has m ''"unaddressed"'' && has m "address")
        (failingMessages noAddressAssertions);

    # ── fact-wiring: nixdisplay composed elsewhere, layouts genuinely absent -- warn AND fail ──
    "layouts genuinely absent (nixdisplay composed via an unrelated leaf) warns" =
      renamedWarnings != [ ] && lib.any (w: has w "nixdisplay.layouts") renamedWarnings;
    "the same case also fails the build, not just warns" =
      lib.any (a: !a.assertion) renamedAssertions;

    # ── the quiet baseline: nothing named, nothing composed -- silent and correct ──────────────
    "with no layout/session named, nothing warns" = quietWarnings == [ ];
    "with no layout/session named, nothing fails" = lib.all (a: a.assertion) quietAssertions;
    "with no layout/session named, the auto-detect comment is rendered" =
      has quietRendered "Ciri auto-detects";
    "with no layout/session named, no debug block is rendered" =
      !(has quietRendered "debug {");

    # ── NON-VACUITY ─────────────────────────────────────────────────────────────────────────────
    "every render used above is a real, non-empty config" =
      lib.all (s: lib.stringLength s > 200) [ manualRendered layoutRendered sessionRendered quietRendered ];
  };

  failed = lib.attrNames (lib.filterAttrs (_: passed: !passed) results);
in
if failed == [ ]
# `pkgs.emptyFile`, not a `runCommand` marker -- see checks/startup-contract.nix's own comment on
# why a runCommand output path is system-dependent and breaks `--all-systems` on a foreign arch.
then pkgs.emptyFile
else throw ''
  nixciri: the structured output/layout/session seam is broken. Failing assertions:
  ${lib.concatMapStringsSep "\n" (f: "  - ${f}") failed}
''
