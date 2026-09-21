# SPDX-License-Identifier: MIT OR Apache-2.0
# checks/output-accepted.nix — feed this module's rendered config.kdl to the upstream Niri
# validator whose grammar Ciri currently inherits.
#
# WHY THIS EXISTS. Every check in checks/output-contract.nix evaluates Nix and inspects the
# result, which can only prove the module renders what it intended. It cannot prove the parser agrees --
# and for a config generator that is the only question that matters in the end. This mirrors
# nixscroll's checks/config-accepted.nix (same "run the real binary against this module's own
# output" doctrine), with one simplification: unlike scroll's `--validate` (which exits 0 even
# having rejected every directive, forcing a stderr grep), the upstream `validate` subcommand exits
# NON-ZERO on a rejected config -- confirmed empirically against the real binary (26.04, 2026-07)
# before writing this check -- so this one gates on the exit status directly.
{ pkgs, upstreamValidator, ciriModule }:
let
  lib = pkgs.lib;
  validator = lib.getExe upstreamValidator;

  # Minimal stand-in for the home-manager surface the module writes into -- see
  # checks/startup-contract.nix and checks/output-contract.nix for the same doctrine.
  hmStub = { lib, ... }: {
    options = {
      xdg.configFile = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
      home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = [ ]; };
      home.file = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
      systemd.user = lib.mkOption { type = lib.types.anything; default = { }; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.unspecified; default = [ ]; };
      warnings = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ ]; };
    };
  };

  # Minimal stand-ins for nixdisplay's monitor/layout producers and nixdesktop's session producer.
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
    config.nixdisplay.layouts.docked.outputs = [
      {
        monitor = "u4323qe";
        match = "identity";
        mode = "3840x2160@60";
        scale = 1.5;
        position = { x = 0; y = 0; };
        transform = "90";
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
    config.nixdesktop.sessions.primary = {
      permittedDevices = [ "ast" ];
      deniedDevices = [ "amd" "evdi" ];
    };
  };

  # Minimal stand-in for nixgpu's `stableDevicePaths.devices` -- see checks/output-contract.nix
  # for why this is narrow (just the three fields home/ciri.nix's own `devicePathFor` reads)
  # rather than a reimplementation of nixgpu's own schema. "ast" and "evdi" both have
  # `renderPath = null` (a BMC framebuffer and a platform device never have one, by driver fact),
  # proving the real parser below accepts a `debug` block built from card-only paths too;
  # "amd" has both, proving the ordinary GPU case in the same real-binary pass.
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
    };
  };

  # One config exercising a broad spread of the option surface -- manual outputs (with a
  # modeline, a scale, a position, a non-default transform), a translated layout (identity +
  # alias + connector-off), a translated session (denylist + primary render device), the raw
  # escape hatch, and an ordinary keybind alongside all of it -- not a minimal smoke test. Same
  # doctrine as nixscroll's config-accepted.nix fixture: an option absent from this fixture is an
  # option no one has ever asked the parser about.
  fixture = {
    programs.ciri.enable = true;
    programs.ciri.layout = "docked";
    programs.ciri.session = "primary";
    # This is the exact package whose validator runs below, not a version stand-in.
    programs.ciri.package = upstreamValidator;
    programs.ciri.outputs."DP-2" = {
      mode = "1920x1080@60";
      modeline = "148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync";
      scale = 1.0;
      position = {
        x = 3840;
        y = 0;
      };
      transform = "flipped";
    };
    programs.ciri.extraOutputs = ''
      output "HDMI-A-2" {
          off
      }
    '';
    programs.ciri.binds = {
      "Mod+Y" = ''spawn "true"'';
      "Mod+Escape" = {
        action = ''spawn-sh "nixlock -f"'';
        hotkeyOverlayTitle = "Lock the Session";
        repeat = false;
      };
      "Mod+Down" = "focus-window-or-workspace-down";
      "Mod+Ctrl+Down" = "move-window-down-or-to-workspace-down";
      "Mod+Shift+R" = "switch-preset-column-width-back";
      "Mod+M" = "maximize-window-to-edges";
      "Mod+Minus" = ''set-column-width "-10%"'';
      "Mod+V" = "toggle-window-floating";
      "Ctrl+Print" = "screenshot-screen";
      "Alt+Print" = "screenshot-window";
      "Mod+Shift+P" = "power-off-monitors";
      "XF86AudioRaiseVolume" = {
        action = ''spawn "swayosd-client" "--output-volume" "raise"'';
        allowWhenLocked = true;
      };
      "Mod+Ctrl+Escape" = {
        action = "toggle-keyboard-shortcuts-inhibit";
        allowInhibiting = false;
        repeat = false;
      };
    };
    programs.ciri.extraTopLevel = ''
      input {
          keyboard {
              xkb {
                  layout "ch"
                  variant "de_nodeadkeys"
              }
              numlock
          }
          touchpad {
              tap
              natural-scroll
          }
      }

      layout {
          gaps 6
          center-focused-column "never"
          preset-column-widths {
              proportion 0.25
              proportion 0.5
              proportion 0.75
          }
          default-column-width { proportion 0.5; }
          focus-ring {
              width 2
              active-color "#B45309"
              inactive-color "#505050"
          }
      }

      hotkey-overlay {
          skip-at-startup
      }

      screenshot-path "~/Pictures/Screenshots/Screenshot from %Y-%m-%d %H-%M-%S.png"
    '';
  };

  evaluated = (lib.evalModules {
    modules = [ hmStub ciriModule layoutsFixture monitorsFixture sessionsFixture stableDevicePathsFixture fixture ];
    specialArgs = { inherit pkgs; };
  }).config;

  rendered = evaluated.xdg.configFile."ciri/config.kdl".text;

  # FORCED here, at Nix eval time, before this derivation is even built -- an assertion that
  # fired would mean this whole check is asking the real parser about a config nixciri
  # itself does not believe is valid, which is a strictly less useful thing to have proven.
  # `assert` throws with the *first* failing message, which is enough to find the rest from.
  failedAssertion = lib.findFirst (a: !a.assertion) null evaluated.assertions;
  rendered' =
    assert (failedAssertion == null || throw "nixciri: this check's own fixture fails an assertion: ${failedAssertion.message}");
    rendered;

  # The one thing every check in checks/output-contract.nix cannot prove: this file evaluates
  # Nix, not the parser, so a rendered config asserting the right things could still contain the wrong
  # STRINGS. Forced here rather than left to the real-binary check below, so a regression back to
  # bare device names is a clear, named Nix-level failure instead of an opaque parser rejection.
  # The inherited parser accepts a bare name as a syntactically valid but useless string.
  rendered'' =
    assert (lib.hasInfix "/dev/dri/by-path/" rendered'
      || throw "nixciri: the rendered debug block contains no /dev/dri/by-path/* path -- device restriction regressed back to bare names.");
    rendered';

  configFile = pkgs.writeText "ciri-fixture-config.kdl" rendered'';

  # A config that MUST be rejected -- this check's own self-test, same shape as nixscroll's
  # `poison` fixture in checks/config-accepted.nix.
  poison = pkgs.writeText "ciri-poison.kdl" ''
    bogus-directive-ciri-cannot-know true
  '';
in
pkgs.runCommand "ciri-output-accepted"
{
  inherit configFile poison validator;
}
  ''
    set +e

    # ── SELF-TEST FIRST ────────────────────────────────────────────────────────────────────────
    # Prove the validator actually parses configs in THIS sandbox before believing anything it
    # says about ours -- a green result from a validator that never ran is precisely the failure
    # this check exists to catch, and it is not entitled to exempt itself from it.
    "$validator" validate -c "$poison" > poison.log 2>&1
    poisonExit=$?
    echo "== poison config (must be REJECTED) =="
    cat poison.log
    if [ "$poisonExit" -eq 0 ]; then
      echo "FAIL: the self-test config was NOT rejected, so the validator never parsed it here."
      echo "This check cannot report anything about the real config until that is fixed."
      exit 1
    fi
    echo "self-test OK: the validator rejects a known-bad directive in this environment."
    echo

    # ── THE ACTUAL CHECK ───────────────────────────────────────────────────────────────────────
    echo "== validating the rendered config against $($validator --version) =="
    cat "$configFile"
    "$validator" validate -c "$configFile" > out.log 2>&1
    goodExit=$?
    cat out.log
    if [ "$goodExit" -ne 0 ]; then
      echo
      echo "FAIL: the validator rejected nixciri's structured outputs/layout/session config."
      echo "The parse error above names the line; either the option should not exist,"
      echo "or it renders the wrong spelling."
      exit 1
    fi

    echo "OK: the upstream grammar validator accepts the rendered Ciri config."
    touch $out
  ''
