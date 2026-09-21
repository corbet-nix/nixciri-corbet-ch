# SPDX-License-Identifier: MIT OR Apache-2.0
# home/ciri.nix — homeManagerModules.ciri: generate ~/.config/ciri/config.kdl from
# structured options in the programs.ciri namespace.
#
# This public module owns mechanism only. It ships no keyboard choice, bindings, colors,
# application rules, workspace count, locker, OSD, bar, launcher, or polkit agent. Those are
# private desktop values or responsibilities of their own products. The only implicit content
# is translation of neutral contracts which a consumer explicitly selects.
#
# `probeFact`/`collectProbes` ARE TAKEN AS A MODULE ARGUMENT, closed over by flake.nix against
# the real `nixhost.lib` (see flake.nix's own `nixhost` input comment) — the same shape
# nixscroll's `home/scroll.nix` and nixdesktop's own `modules/session.nix` already use. This is
# the probeFact MECHANISM only: neither nixdesktop nor nixgpu is ever a flake input here, and
# everything read through it below (`nixdisplay.layouts`, `nixdisplay.monitors`,
# `nixdesktop.sessions`, `nixgpu.stableDevicePaths.devices`) renders nothing at all on a host
# that never composed the sibling that owns it, silently and correctly.
{ probeFact, collectProbes }:
{ lib, config, options, ... }:
let
  cfg = config.programs.ciri;

  # The neutral `nixdesktop.startup` contract, consumed rather than hand-wired.
  #
  # Read DEFENSIVELY (`or [ ]`): a host running Ciri without nixdesktop sees an
  # empty list and renders nothing extra, never an evaluation error. That is what keeps this a
  # one-way dependency -- nixdesktop declares the contract and knows nothing about Ciri; this
  # module reads it and adapts. Reversing that (nixdesktop reading `programs.ciri.*`) would
  # re-couple the neutral policy layer to one compositor by name, which is the whole thing its
  # split was for.
  #
  # `spawn-sh-at-startup`, not `spawn-at-startup`: contract entries are shell command strings,
  # while Ciri's plain spawn form takes argv.
  neutralStartup =
    map (c: ''spawn-sh-at-startup "${c}"'') (config.nixdesktop.startup or [ ]);

  # ── Structured output rendering ─────────────────────────────────────────────────────────────
  #
  # Replaces the former `programs.ciri.output` -- a single raw-KDL string interpolated once for
  # every monitor on every host, which meant nothing here could ever be asserted and no registry
  # could key on it (a host moving a monitor to a different machine got a block that silently
  # stopped applying, with no build-time signal anywhere). Two producers feed the same renderer:
  #
  #   `cfg.outputs`  -- hand-authored per output, host-specific, the escape/manual path.
  #   `cfg.layout`   -- a `nixdisplay.layouts.<name>`, translated automatically, portable between
  #                     hosts because it is keyed by the shared monitor registry rather than by
  #                     hand-copied EDID text.
  #
  # Both go through `renderOutputBlock`, so there is exactly one place that knows how to turn a
  # resolved output record into Ciri KDL -- the "everything that can be got wrong twice is got
  # right once" doctrine this whole family follows.

  # Ciri inherits Niri's rule that output-match arguments are always double-quoted -- connector
  # names and identity triples alike (`output "eDP-1" { ... }`,
  # `output "Some Company CoolMonitor 1234" { ... }`, both from
  # Niri's upstream docs) -- unlike sway/scroll, which need quoting only when the identity
  # triple itself contains a space. Quoting unconditionally means a plain connector name and a
  # multi-word identity triple go through one code path instead of two. Same escaping doctrine as
  # nixscroll's `home/scroll.nix` `quoteName` -- double quotes are documented KDL grammar here,
  # not a shell-quoting convention, so this is not `lib.escapeShellArg`.
  quoteKdl = n: ''"${lib.replaceStrings [ ''"'' ] [ ''\"'' ] n}"'';

  # niri's `modeline` directive (KDL, since niri 25.11) takes the SAME nine timing numbers, in
  # the SAME order, as nixdisplay's neutral `modeline` string (`modules/layouts.nix`) -- but Ciri
  # wants its trailing sync-polarity flags as QUOTED KDL strings (`"-hsync" "+vsync"`), while the
  # neutral spelling, copied verbatim from sway/scroll's own unquoted grammar, carries none.
  # Requoting only the trailing tokens is the ENTIRE translation; the nine leading numbers pass
  # through byte-identical, and so does their order (verified against niri's own modeline example:
  # `173.00 1920 2048 2248 2576 1080 1083 1088 1120 "-hsync" "+vsync"` is pixelclock/hdisp/
  # hsyncstart/hsyncend/htotal/vdisp/vsyncstart/vsyncend/vtotal, the identical field order
  # nixdisplay's own `parseModeline` reads fields 2 and 6 out of).
  renderModeline =
    raw:
    let
      toks = lib.filter (t: t != "")
        (lib.splitString " " (lib.replaceStrings [ "\t" "\n" ] [ " " " " ] raw));
      numeric = lib.take 9 toks;
      flags = lib.drop 9 toks;
    in
    lib.concatStringsSep " " (numeric ++ map (f: ''"${f}"'') flags);

  # The shared field shape both `cfg.outputs` entries and a translated
  # `nixdisplay.layouts.<name>.outputs.*` entry present to the renderer below. Mirrors the shape
  # nixscroll's own `programs.scroll.outputs` submodule already uses (an attrset of typed fields
  # per output), not its exact field list -- niri's own directives differ from scroll's.
  outputEntryOptions = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this output is on. `false` renders Ciri's `off` flag and nothing else.
      '';
    };

    mode = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "3840x2160@60";
      description = ''
        `WIDTHxHEIGHT@REFRESH`, or `null` to let Ciri auto-detect. The refresh rate, if given,
        must match what `ciri msg outputs` reports down to the same decimal digits.
      '';
    };

    modeline = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "148.50 1920 2008 2052 2200 1080 1084 1089 1125 +hsync +vsync";
      description = ''
        A raw modeline in nixdisplay's neutral, UNQUOTED spelling -- nine timing numbers then
        bare sync flags (`+hsync +vsync`), the identical string
        `nixdisplay.layouts.<name>.outputs.*.modeline` carries. This module requotes the
        trailing flags for Ciri's grammar (see `renderModeline` above); write it unquoted
        here regardless of which compositor eventually reads it. `null` (default) omits the
        directive.
      '';
    };

    scale = lib.mkOption {
      type = lib.types.nullOr lib.types.numbers.positive;
      default = null;
      example = 1.5;
      description = "Logical-pixel scale, or `null` for Ciri's guess from physical size.";
    };

    position = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          x = lib.mkOption { type = lib.types.int; description = "Logical-pixel X."; };
          y = lib.mkOption { type = lib.types.int; description = "Logical-pixel Y."; };
        };
      });
      default = null;
      description = ''
        Top-left corner in Ciri's logical coordinate space, or `null` for automatic placement.
      '';
    };

    transform = lib.mkOption {
      type = lib.types.enum [
        "normal"
        "90"
        "180"
        "270"
        "flipped"
        "flipped-90"
        "flipped-180"
        "flipped-270"
      ];
      default = "normal";
      description = ''
        How the output is turned, COUNTER-CLOCKWISE -- Ciri's vocabulary. Read from
        nixdisplay's neutral `nixdisplay.layouts` (identical spelling, identical direction),
        this PASSES THROUGH UNCHANGED: contrast nixscroll's translator, which must swap
        90<->270 and flipped-90<->flipped-270 because sway/scroll's own grammar is clockwise.
        See nixdisplay's `modules/layouts.nix` `transform` option for the measured detail.
        Getting either translator's direction wrong rotates a monitor backwards in a way
        invisible from either compositor's own IPC (sway inverts back when reporting).
      '';
    };
  };

  # One `output "..." {}` block. `matchName` is whatever Ciri should match on -- a connector
  # name or an identity triple -- this function has no opinion which; `o` is any record carrying
  # the fields in `outputEntryOptions` above (a `cfg.outputs.<name>` submodule value, or a plain
  # attrset built from a translated `nixdisplay.layouts` entry -- both are read identically).
  renderOutputBlock =
    matchName: o:
    let
      body =
        if !o.enable then [ "off" ]
        else lib.filter (l: l != null) [
          (if o.mode != null then "mode ${quoteKdl o.mode}" else null)
          (if o.modeline != null then "modeline ${renderModeline o.modeline}" else null)
          (if o.scale != null then "scale ${toString o.scale}" else null)
          (if o.position != null
            then "position x=${toString o.position.x} y=${toString o.position.y}"
            else null)
          "transform ${quoteKdl o.transform}"
        ];
    in
    ''
      output ${quoteKdl matchName} {
          ${lib.concatStringsSep "\n    " body}
      }'';

  # ── Consuming nixdisplay.layouts / nixdisplay.monitors, through lib.probeFact ────────────────
  #
  # Both are `let`-bound but never FORCED unless `cfg.layout != null` actually asks for them
  # (Nix bindings are lazy) -- so a host that never sets `programs.ciri.layout` pays nothing and,
  # crucially, never sees a spurious "did not resolve" warning for a namespace it was never
  # trying to read in the first place. See the `layout` option below for why gating on intent
  # rather than probing unconditionally is the right call here: a consumer may import this module
  # without composing nixdisplay at all.
  layoutsProbe = probeFact {
    inherit config;
    namespace = "nixdisplay";
    path = [ "layouts" ];
    fallback = { };
  };

  monitorsProbe = probeFact {
    inherit config;
    namespace = "nixdisplay";
    path = [ "monitors" ];
    fallback = { };
  };

  # nixdisplay.layouts.<cfg.layout>.outputs, translated into one-or-more resolved output records
  # each fed to `renderOutputBlock`. An entry addressed `match = "connector"` becomes exactly one
  # block, keyed by its connector name. An entry addressed `match = "identity"` becomes one block
  # PER IDENTITY VARIANT the panel can present -- its own `identifier` AND every one of its
  # `aliases`' `identifier`s, because the SAME physical panel reports a DIFFERENT EDID per input
  # (nixdisplay's `modules/monitors.nix` header) and Ciri matches on whichever string the
  # connected wire happens to report. A block missing for the currently-live variant behaves
  # exactly like no block at all -- the output silently keeps its default mode/position/scale --
  # so every variant gets the identical rendered fields.
  layoutOutputBlocks =
    if cfg.layout == null then [ ]
    else
      let
        layout = layoutsProbe.value.${cfg.layout};
        resolvedEntry = o: {
          inherit (o) enable mode modeline scale position transform;
        };
        matchNamesOf = o:
          if o.match == "connector" then [ o.connector ]
          else
            let m = monitorsProbe.value.${o.monitor}; in
            [ m.identifier ] ++ map (a: a.identifier) m.aliases;
      in
      lib.concatMap
        (o: map (name: renderOutputBlock name (resolvedEntry o)) (matchNamesOf o))
        layout.outputs;

  # ── Consuming nixdesktop.sessions.<cfg.session>.{permittedDevices,deniedDevices} ─────────────
  #
  # Ciri has no allowlist -- it enumerates every DRM device on the seat unconditionally -- so the
  # only lever is `debug { ignore-drm-device }`, the COMPLEMENT of the permitted set over the
  # WHOLE inventory (already computed once, by nixdesktop's own `modules/session.nix`), plus
  # `debug { render-drm-device }` naming the single PRIMARY permitted device
  # (`permittedDevices` is ordered primary-first: "exclusive" claims before "shared" ones -- see
  # nixdesktop's own module). This is why nixdesktop's device inventory must be COMPLETE: a
  # device that exists but was never declared there is in NEITHER list, so it is never ignored
  # and leaks straight into Ciri's enumeration.
  #
  # nixdesktop hands back DEVICE NAMES ("amd", "ast", "evdi"), not paths -- see
  # `permittedDevices`/`deniedDevices`'s own option headers in nixdesktop's `modules/session.nix`.
  # A launcher resolving a NAME to a live path at process-start time is the right answer for
  # scroll, because `WLR_DRM_DEVICES` is an environment variable wlroots reads when it starts --
  # but Ciri reads `debug { render-drm-device; ignore-drm-device; }` straight out of config.kdl
  # ON DISK, with no launcher step in between, so a bare name sitting in that file matches no
  # live device Ciri has ever heard of and enforces no restriction at all while looking like
  # perfectly valid KDL. `stableDevicePathsProbe` below is the second half of the translation
  # this file owns: NAME -> stable `/dev/dri/by-path/*` PATH, resolved at Nix eval time via
  # `nixgpu.stableDevicePaths.devices` (the same registry nixdesktop's own inventory mirror is
  # keyed from) -- see `devicePathFor`.
  sessionsProbe = probeFact {
    inherit config;
    namespace = "nixdesktop";
    path = [ "sessions" ];
    fallback = { };
  };

  # The inherited Niri `debug` namespace is outside the stable config contract, so this module
  # pins itself to the exact compatible version range its
  # `render-drm-device`/`ignore-drm-device` translation was verified against, rather than
  # trusting "it happens to still parse". `ignore-drm-device` shipped in niri 25.11 (niri's own
  # Configuration: Debug Options wiki page: "Since: 25.11") -- a niri older than that has no way
  # to express a denylist at all, so this module's whole device-restriction mechanism is
  # unavailable below it. No upper bound yet: raise this once a future Ciri rebase is verified
  # to have renamed or dropped either key.
  minCiriDebugDeviceVersion = "25.11";

  stableDevicePathsProbe = probeFact {
    inherit config;
    namespace = "nixgpu";
    path = [ "stableDevicePaths" "devices" ];
    fallback = { };
  };

  # `renderPath` is preferred (niri's own wiki examples exclusively show `renderD*` paths), but
  # `cardPath` is not a fallback of last resort -- it is the CORRECT, COMPLETE answer for a
  # device niri's own source proves has no render node to name. Verified against niri's real
  # `primary_node_from_render_node` (niri 26.04, `src/backend/tty.rs`; both `render-drm-device`
  # and `ignore-drm-device` route through it): given a path that is not itself a render node, it
  # looks up that node's render-node SIBLING and uses it, and when no sibling exists at all --
  # exactly the evdi / AST-BMC-framebuffer case, `hasRenderNode = false` -- it falls back to the
  # node it was given, for both halves of the pair, logging a warning and returning no error. So
  # a card-only device's `cardPath` resolves correctly here, matching niri's own documented
  # fallback rather than working around it.
  devicePathFor = deviceName:
    let d = stableDevicePathsProbe.value.${deviceName};
    in if d.renderPath != null then d.renderPath else d.cardPath;

  deviceDebugLines =
    if cfg.session == null then [ ]
    else
      let
        s = sessionsProbe.value.${cfg.session};
        permitted = s.permittedDevices;
        denied = s.deniedDevices;
      in
      lib.optional (permitted != [ ])
        "render-drm-device ${quoteKdl (devicePathFor (lib.head permitted))}"
      ++ map (d: "ignore-drm-device ${quoteKdl (devicePathFor d)}") denied;

  # REAL /dev/dri/by-path/* PATHS, not device names -- the opposite of what an earlier version of
  # this file rendered here. Ciri reads `debug { render-drm-device; ignore-drm-device; }`
  # STRAIGHT OUT OF config.kdl ON DISK; there is no launcher step between home-manager writing
  # this file and Ciri parsing it, so a bare NAME here (unlike scroll's `WLR_DRM_DEVICES`, an
  # environment variable a launcher genuinely can still resolve at process-start time) would
  # parse as a perfectly valid config that restricts nothing: Ciri matches it against a live
  # sysfs path, finds no device by that name, and enumerates every DRM device on the seat exactly
  # as if `session` had never been set -- silently. `address`, and `cardPath`/`renderPath` derived
  # from it, ARE knowable at Nix eval time (a PCI slot or platform device name, fixed at
  # build/install time, unlike a card NUMBER, which is enumeration order and genuinely
  # renumbers -- see nixgpu's own `stableDevicePaths.devices.<name>.address` header), which is
  # exactly what lets this module bake the real path in here instead of deferring to a runtime
  # resolver Ciri would never call.
  deviceDebugBlock =
    if deviceDebugLines == [ ] then ""
    else
      ''

        // VOLATILE: both keys below live under the inherited unstable `debug` namespace.
        // programs.ciri.package turns compatibility into a build-time assertion.
        debug {
            ${lib.concatStringsSep "\n    " deviceDebugLines}
        }'';

  # Every block this module knows how to produce, in one list: hand-authored entries first
  # (`cfg.outputs`, keyed by `lib.attrNames` order, which Nix guarantees sorted), then the
  # layout-derived blocks, then the raw escape hatch. Attribute-name order is stable and
  # cosmetic-only here -- Ciri applies whichever block matches the live output, regardless of
  # where in the file it appears.
  outputsSection =
    let
      manualBlocks = lib.mapAttrsToList renderOutputBlock cfg.outputs;
      allBlocks = manualBlocks ++ layoutOutputBlocks;
    in
    if allBlocks == [ ] && cfg.extraOutputs == "" then
      ''
        // No output declared -- Ciri auto-detects. Run `ciri msg outputs` on-box to find the
        // real name if you want to pin mode/scale/position: `programs.ciri.outputs` (manual,
        // per-host) or `programs.ciri.layout` (nixdisplay-derived, portable between hosts).
      ''
    else
      lib.concatStringsSep "\n\n" (allBlocks ++ lib.optional (cfg.extraOutputs != "") cfg.extraOutputs);

  # A bind is either a bare action string -- shorthand for "no hotkey-overlay title, no
  # flags", which covers most movement/layout binds -- or the full submodule below, for
  # when a bind needs a title or one of the flags Ciri supports on a bind. `action` is raw
  # KDL, written exactly as it appears inside the bind's `{ }` block (`close-window`,
  # `spawn "foo"`, `spawn-sh "foo | bar"`, `toggle-overview`, ...); this module supplies the
  # surrounding `{ ...; }` and the trailing semicolon.
  bindType = lib.types.submodule {
    options = {
      action = lib.mkOption {
        type = lib.types.str;
        example = ''spawn "my-terminal"'';
        description = "The Ciri action this bind runs, written exactly as it appears inside the bind's `{ }` block.";
      };

      hotkeyOverlayTitle = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "Open a Terminal";
        description = ''
          Label shown for this bind in Ciri's hotkey overlay. Null, the default, omits the
          field -- Ciri leaves untitled binds out of the overlay
          entirely, rather than listing them with a blank label.
        '';
      };

      allowWhenLocked = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether the bind still fires while the session is locked. Ciri's default is false.
        '';
      };

      repeat = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether holding the key repeats the action. Ciri's default is true; set
          false for actions that only make sense once per press, like closing a window.
        '';
      };

      allowInhibiting = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether an application requesting exclusive keyboard-shortcut access (a game, a
          VM viewer) is allowed to swallow this bind. Ciri's default is true.
        '';
      };
    };
  };

  # Render the flags that go between a bind's key combo and its `{ }` block. Only ever
  # emits a flag when it differs from Ciri's default (see the options above) -- e.g.
  # plain `Mod+Left { focus-column-left; }`, never `Mod+Left repeat=true { ...; }`.
  renderBindFlags = b: lib.concatStringsSep " " (
    lib.optional (b.hotkeyOverlayTitle != null) ''hotkey-overlay-title="${b.hotkeyOverlayTitle}"''
    ++ lib.optional b.allowWhenLocked "allow-when-locked=true"
    ++ lib.optional (!b.repeat) "repeat=false"
    ++ lib.optional (!b.allowInhibiting) "allow-inhibiting=false"
  );

  # Render one `binds { }` line for one `cfg.binds` entry. `null` -- a removed bind -- drops
  # out via the `lib.filter` in `bindsSection` below.
  renderBind = name: value:
    if value == null then
      null
    else if builtins.isString value then
      "${name} { ${value}; }"
    else
      let
        flags = renderBindFlags value;
      in
      "${name}${lib.optionalString (flags != "") " ${flags}"} { ${value.action}; }";

  # `lib.mapAttrsToList` walks `cfg.binds` in `builtins.attrNames` order, which Nix
  # guarantees is sorted -- so the rendered block is alphabetical by key combo. Cosmetic
  # only: Ciri does not care what order binds appear in within `binds { }`.
  bindsSection = lib.concatStringsSep "\n    " (
    lib.filter (l: l != null) (lib.mapAttrsToList renderBind cfg.binds)
  );

  bindsBlock =
    if bindsSection == "" && cfg.extraBinds == "" then ""
    else ''
      binds {
          ${bindsSection}
          ${cfg.extraBinds}
      }
    '';
in
{
  options.programs.ciri = {
    enable = lib.mkEnableOption "declarative Ciri config (~/.config/ciri/config.kdl)";

    outputs = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule { options = outputEntryOptions; });
      default = { };
      example = lib.literalExpression ''
        {
          "eDP-1" = { enable = false; };
          "Dell Inc. DELL U4323QE 9BQR2P3" = {
            mode = "3840x2160@60";
            scale = 1.5;
            position = { x = 0; y = 0; };
          };
        }
      '';
      description = ''
        One Ciri `output "..." {}` block per entry, keyed by the exact string Ciri should match
        an output against -- a connector name ("eDP-1", "HDMI-A-1") or the
        "<make> <model> <serial>" identity triple (see nixdisplay's `modules/monitors.nix` for
        how that triple is built, on a host that composes it). This module never inspects the
        key: it quotes it and writes it, unconditionally, the identical structural shape
        nixscroll's `programs.scroll.outputs` already uses.

        THE MAIN PATH for a host with no `nixdisplay.layouts` to name -- this REPLACES the
        former `programs.ciri.output` (a single raw-KDL string interpolated once for every
        monitor, in which nothing could ever be asserted and no registry could key on it). On a
        host that composes nixdisplay, prefer naming a `layout` (below) instead of hand-filling
        this option: a layout is portable between hosts and keyed by the shared registry, this
        option is host-specific hand-typed text. The two are additive -- both render into the
        same generated file -- for the case where a host wants nixdisplay's registry for most
        outputs and a hand-authored stanza for one it does not.
      '';
    };

    layout = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "docked";
      description = ''
        A `nixdisplay.layouts.<name>` to render as Ciri output blocks, read through
        `lib.probeFact` (see this file's own top-of-file comment on the `probeFact` module
        argument, and the README on the `nixhost` flake input this needs -- never a flake input
        on nixdisplay itself).

        Each layout entry becomes ONE OR MORE `output {}` blocks: an entry addressed by
        `match = "connector"` becomes exactly one, keyed by its connector name; an entry
        addressed by `match = "identity"` becomes one block per identity variant the panel can
        present -- the monitor's own `identifier` AND every one of its `aliases`' `identifier`s
        (the same panel through a different input reports a different EDID, see nixdisplay's
        `modules/monitors.nix` header) -- because Ciri matches on whichever string the connected
        wire happens to report, and a block missing for the currently-live variant behaves
        exactly like no block at all.

        `transform` passes through unchanged: nixdisplay's neutral vocabulary is
        counter-clockwise, matching `wl_output` (and Ciri's config values) exactly, so this
        translator does no inversion at all. Contrast nixscroll's translator, which MUST swap
        90<->270 and flipped-90<->flipped-270, because sway/scroll's own config grammar is
        clockwise -- see nixdisplay's `modules/layouts.nix` `transform` option for the measured
        detail. Getting either translator's direction wrong rotates a monitor backwards in a
        way invisible from either compositor's own IPC.

        `null` (default) renders no layout-derived blocks at all -- the correct, silent stance
        for a host with no `nixdisplay.layouts` composed, or that only wants `outputs` above.
        Naming a layout that `nixdisplay.layouts` does not declare (or that nixdisplay is not
        composed on this host at all) is a build failure, not a silent no-op -- see this
        module's own `assertions`.
      '';
    };

    session = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "primary";
      description = ''
        A `nixdesktop.sessions.<name>` whose resolved `permittedDevices`/`deniedDevices`
        becomes this Ciri instance's device restriction, read through `lib.probeFact`. Ciri has
        NO allowlist -- it enumerates every DRM device on the seat unconditionally -- so the
        only lever is `debug { ignore-drm-device }`, one per device this session may NOT touch
        (the complement of the permitted set over the WHOLE inventory, already computed by
        nixdesktop's `modules/session.nix`), plus `debug { render-drm-device }` naming the
        single PRIMARY permitted device. This is why nixdesktop's device inventory must be
        COMPLETE: a device that exists but was never declared is in neither list, so it is
        never ignored and leaks straight into Ciri's enumeration.

        nixdesktop hands back DEVICE NAMES ("amd", "ast", "evdi"); this module resolves each one
        to a stable `/dev/dri/by-path/*` PATH via `nixgpu.stableDevicePaths.devices.<name>.
        {cardPath,renderPath}` (also read through `lib.probeFact`) and renders PATHS, never
        names, into the `debug` block. That resolution has to happen HERE, at Nix eval time:
        Ciri reads `config.kdl` straight off disk, with no launcher step in between, so a bare
        name would parse as valid KDL matching no live device and enforce nothing at all --
        silently. A card NUMBER (`/dev/dri/card1`) is the one spelling that could not be used
        instead: DRM minors are enumeration order and genuinely renumber on live hardware (an
        extra DRM device can change enumeration order). `address` does not: it is
        a PCI slot or platform device name, fixed at build/install time, which is exactly what
        makes `cardPath`/`renderPath` safe to bake in here rather than defer to a resolver Ciri
        would never call. Naming a device that `nixgpu.stableDevicePaths.devices` does not
        declare, or that declares no `address`, is a build failure -- see this module's own
        `assertions`.

        Both `debug` keys are inherited from Niri's unstable `debug` namespace. A Ciri rebase can
        rename or remove either with no notice. Setting `session` therefore REQUIRES `package` too (see
        that option, below): this module asserts `package`'s own `.version` is new enough to
        still have these keys, so an incompatible Ciri upgrade fails the build instead of
        silently rendering a `debug` block Ciri no longer understands, and therefore no longer
        enforces.

        `null` (default): no device restriction is rendered at all. Naming a session that
        `nixdesktop.sessions` does not declare (or that nixdesktop is not composed on this host
        at all) is a build failure -- see this module's own `assertions`.
      '';
    };

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression "ciriPackage";
      description = ''
        The real Ciri package this generated config will run under. Used only to assert its
        `.version` -- same doctrine as nixscroll's own `package` option (`home/scroll.nix`):
        never added to `home.packages`, this module installs nothing, a platform backend
        resolves the real binary that actually runs.

        `null` (the default) is fine for a config that never sets `session`: nothing else here
        reads Ciri's inherited volatile `debug` namespace, so there is no version-sensitive
        translation to verify. The moment `session` is set, `package` becomes REQUIRED, by
        assertion, not merely recommended -- device restriction is a security boundary, and
        whether Ciri still has `render-drm-device`/`ignore-drm-device` (upstream Niri explicitly
        excludes `debug` from its config stability policy -- either key can be
        renamed or removed with no notice) is exactly the one fact this module cannot verify
        without a real package to ask.
      '';
    };

    extraOutputs = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra raw KDL, verbatim, appended after every generated `output {}` block -- for
        whatever the structured `outputs`/`layout` surfaces above cannot express (same
        escape-hatch doctrine as `extraWindowRules`/`extraBinds`/`extraTopLevel` below).
      '';
    };

    binds = lib.mkOption {
      type = lib.types.attrsOf (lib.types.nullOr (lib.types.either lib.types.str bindType));
      default = { };
      example = {
        "Mod+T" = ''spawn "my-terminal"'';
        "Print" = null;
        "Mod+Z" = ''spawn "my-script"'';
      };
      description = ''
        Keybindings, keyed by the exact Ciri key-combo string ("Mod+T",
        "XF86AudioRaiseVolume", ...). This module deliberately ships none.

        A plain string is shorthand for a bind with no hotkey-overlay title and no flags --
        the common case. Use the submodule (`action`, `hotkeyOverlayTitle`,
        `allowWhenLocked`, `repeat`, `allowInhibiting`) when a bind needs either.

        Define a key to add a bind. Set a locally merged key to `null` to remove it.
      '';
    };

    extraStartup = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ ''spawn-at-startup "desktop-component"'' ];
      description = "Extra raw spawn-at-startup / spawn-sh-at-startup lines, verbatim.";
    };

    extraWindowRules = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = "Raw `window-rule {}` blocks, verbatim. This module ships no rules.";
    };

    extraBinds = lib.mkOption {
      type = lib.types.lines;
      default = "";
      description = ''
        Extra raw keybind lines, verbatim, appended inside the `binds {}` block after every
        entry from the `binds` option above. The bind submodule models
        `hotkey-overlay-title`, `allow-when-locked`, `repeat`, and `allow-inhibiting`.
        Ciri's bind syntax is larger than this typed surface; use this escape hatch for an
        unmodelled property such as `cooldown-ms`.
      '';
    };

    extraTopLevel = lib.mkOption {
      type = lib.types.lines;
      default = "";
      example = ''
        debug {
            enable-overlay-planes
        }
      '';
      description = ''
        Extra raw top-level KDL blocks, verbatim, appended at the end of the file (outside
        `binds {}`/`window-rule {}` -- for things like a `debug {}` block).
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {

    # ── The seams read through lib.probeFact, both gated on the option that expresses intent ──
    #
    # Neither seam probes unconditionally: see `layoutsProbe`/`monitorsProbe`/`sessionsProbe`
    # above for why an always-on probe would misreport "nixdisplay.layouts was renamed" about a
    # host that simply never named a `layout` (or a `session`) in the first place.
    assertions =
      lib.optionals (cfg.layout != null) (
        [{
          assertion = layoutsProbe.value ? ${cfg.layout};
          message = ''
            programs.ciri.layout names "${cfg.layout}", which nixdisplay.layouts does not
            declare (or nixdisplay.layouts is not composed on this host at all). Declared:
            ${if layoutsProbe.value == { }
              then "  (none)"
              else lib.concatMapStringsSep "\n" (n: "  - ${n}") (lib.attrNames layoutsProbe.value)}
          '';
        }]
        ++ lib.optionals (layoutsProbe.value ? ${cfg.layout}) (map
          (o: {
            assertion = o.match != "identity" || monitorsProbe.value ? ${o.monitor};
            message = ''
              programs.ciri.layout "${cfg.layout}" addresses monitor "${o.monitor}" by
              identity, but nixdisplay.monitors does not declare that slug (or
              nixdisplay.monitors is not composed on this host at all). Without it there is
              no "<make> <model> <serial>" triple to emit -- either compose
              nixdisplay.monitors, or address this output by connector instead.
            '';
          })
          layoutsProbe.value.${cfg.layout}.outputs)
      )
      ++ lib.optional (cfg.session != null) {
        assertion = sessionsProbe.value ? ${cfg.session};
        message = ''
          programs.ciri.session names "${cfg.session}", which nixdesktop.sessions does not
          declare (or nixdesktop.sessions is not composed on this host at all). Declared:
          ${if sessionsProbe.value == { }
            then "  (none)"
            else lib.concatMapStringsSep "\n" (n: "  - ${n}") (lib.attrNames sessionsProbe.value)}
        '';
      }

      # ── device restriction is a security boundary: pin the Ciri version ──────────────
      #
      # The inherited `debug` namespace is outside upstream's stable config contract, so trusting
      # that `render-drm-device`/`ignore-drm-device` still exist is exactly the silent-regression
      # risk this mechanism closes. A real `package` is what
      # lets this module ask instead of assume -- a warning alone (what this module used to
      # ship) never stops a build, so an upgrade that drops both keys would still converge.
      ++ lib.optional (cfg.session != null) {
        assertion = cfg.package != null;
        message = ''
          programs.ciri.session = "${toString cfg.session}" renders Ciri's
          `debug { render-drm-device; ignore-drm-device; }` block. The inherited namespace is
          unstable and a rebase can rename either key. Set programs.ciri.package to the real Ciri
          derivation so this module can assert its version.
        '';
      }
      ++ lib.optional (cfg.session != null && cfg.package != null) {
        assertion = lib.versionAtLeast cfg.package.version minCiriDebugDeviceVersion;
        message = ''
          programs.ciri.session = "${toString cfg.session}" needs a Ciri version based on Niri >=
          ${minCiriDebugDeviceVersion}, where `ignore-drm-device` first exists.
          programs.ciri.package is ${cfg.package.version}. Device restriction has no fallback.
        '';
      }

      # ── every device this session names must resolve to a real, stable path ────────────────
      #
      # A name absent from nixgpu.stableDevicePaths.devices (or present with no `address`) is
      # not survivable the way an unset `layout`/`session` is: it would either throw a raw,
      # nixgpu-internal error the moment `devicePathFor` forces `cardPath` (see that option's own
      # `readOnly` default in nixgpu), or -- worse, if this module caught that some other way --
      # silently drop one line out of the `debug` block, exactly the "device leaks into Ciri's
      # enumeration" failure this whole mechanism exists to prevent. Naming it here, precisely,
      # beats either.
      ++ lib.optionals (cfg.session != null && sessionsProbe.value ? ${cfg.session}) (
        let
          s = sessionsProbe.value.${cfg.session};
          namedDevices = s.permittedDevices ++ s.deniedDevices;
        in
        map
          (d: {
            assertion = stableDevicePathsProbe.value ? ${d};
            message = ''
              programs.ciri.session = "${cfg.session}" names device "${d}" (via
              nixdesktop.sessions.${cfg.session}.permittedDevices/deniedDevices), which
              nixgpu.stableDevicePaths.devices does not declare (or nixgpu.stableDevicePaths is
              not composed on this host at all). Declared:
              ${if stableDevicePathsProbe.value == { }
                then "  (none)"
                else lib.concatMapStringsSep "\n" (n: "  - ${n}") (lib.attrNames stableDevicePathsProbe.value)}
              Every device a session may render with or must ignore has to resolve to a stable
              /dev/dri/by-path/* entry at eval time -- there is no other moment Ciri's
              config.kdl can be given one.
            '';
          })
          namedDevices
        ++ map
          (d: {
            assertion = !(stableDevicePathsProbe.value ? ${d}) || stableDevicePathsProbe.value.${d}.address != null;
            message = ''
              programs.ciri.session = "${cfg.session}" names device "${d}", but
              nixgpu.stableDevicePaths.devices.${d} declares no `address`. `cardPath`/
              `renderPath` are DERIVED from `address` alone (a PCI domain:bus:device.function or
              platform device name) -- without it neither can be computed, and this module has
              no stable path left to put in Ciri's `debug` block for it. Set
              nixgpu.stableDevicePaths.devices.${d}.address on the GPU-bearing host.
            '';
          })
          namedDevices
      );

    warnings =
      lib.optionals (cfg.layout != null) (collectProbes [ layoutsProbe monitorsProbe ]).warnings
      ++ lib.optionals (cfg.session != null) (collectProbes [ sessionsProbe stableDevicePathsProbe ]).warnings
      ++ lib.optional (deviceDebugLines != [ ]) ''
        programs.ciri.session = "${toString cfg.session}" renders Ciri's
        `debug { render-drm-device; ignore-drm-device; }` block, resolved to real
        /dev/dri/by-path/* paths via nixgpu.stableDevicePaths.devices. Both keys live under
        the inherited unstable `debug` namespace. A Ciri rebase can rename or remove either.
        This module ASSERTS programs.ciri.package's version against the range it was verified
        against (see the `package` option); re-verify that range after every Ciri rebase.
      '';

    xdg.configFile."ciri/config.kdl".text = ''
      // Managed by home-manager (nixciri's home/ciri.nix). Hand edits will be overwritten by
      // the next `home-manager switch` -- set options instead.

      ${outputsSection}

      ${lib.concatStringsSep "\n" (neutralStartup ++ cfg.extraStartup)}

      ${cfg.extraWindowRules}
      ${bindsBlock}
      ${deviceDebugBlock}

      ${cfg.extraTopLevel}
    '';
    })

    # The generic readiness mechanism belongs to nixdesktop; this compositor integration owns
    # the Ciri-specific service/socket translation. When nixdesktop's session module is absent,
    # there is deliberately no definition and standalone config generation remains valid.
    (lib.optionalAttrs (options ? nixdesktop.session.readinessBridge) {
      nixdesktop.session.readinessBridge = lib.mkIf cfg.enable {
        enable = lib.mkDefault true;
        serviceName = lib.mkDefault "ciri";
        socketEnvironment = lib.mkDefault "CIRI_SOCKET";
      };
    })
  ];
}
