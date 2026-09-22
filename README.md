# nixciri

Declarative packaging and desktop integration for Ciri.

`nixciri` generates `~/.config/ciri/config.kdl` from structured Nix options. It
translates neutral display, session-device, and startup contracts into Ciri's KDL
grammar while keeping personal desktop choices outside the public module.

## Boundary

The compositor stack has three layers:

| Layer | Owner | Contains |
|---|---|---|
| Runtime | `ciri` | compositor source, renderer and protocol fixes, CLI and runtime identity |
| Public integration | `nixciri` | pinned package, platform wiring, config serialization and neutral-contract translation |
| Private values | `ciri.nix` | selected layout, bindings, colors, gaps, rules and host overrides |

This repository intentionally ships no keyboard choice, workspace count,
bindings, colors, application rules, bar, launcher, OSD, locker, or polkit
agent. The system modules install the complete public runtime product; the Home
Manager module still installs nothing and only writes the user's config.

## Packages and system modules

| Export | Purpose |
|---|---|
| `packages.<system>.ciri` (`.default`) | exact pinned `corbet-foss/ciri` build with an Arch-safe Nix Mesa/EGL wrapper |
| `nixosModules.ciri` (`.default`) | installs Ciri, companions and the session entry; registers the descriptor when nixdesktop is composed |
| `systemManagerModules.ciri` (`.default`) | exposes Ciri on the system path, registers it with nixdesktop, and delegates its three external companions to pacman |

The compositor descriptor does not contain a wlroots renderer knob. It maps the
neutral `software` renderer intent to `LIBGL_ALWAYS_SOFTWARE=1`; the fork then
accepts software EGL on its real TTY backend and disables dma-buf and DRM leasing
for that renderer. `auto` and `hardware` do not force an implementation.

## Module

| Export | Namespace | Output |
|---|---|---|
| `homeManagerModules.ciri` (`.default`) | `programs.ciri.*` | `~/.config/ciri/config.kdl` |

There are no compatibility aliases. The public API is Ciri-only.

```nix
{
  imports = [ inputs.nixciri.homeManagerModules.ciri ];

  programs.ciri = {
    enable = true;
    layout = "docked";
    session = "primary";
    package = inputs.nixciri.packages.${pkgs.system}.ciri;

    binds."Mod+Return" = {
      action = ''spawn "my-terminal"'';
      hotkeyOverlayTitle = "Open a terminal";
    };
  };
}
```

## Neutral contracts

The module reads sibling options defensively. None of the domain owners below is
a flake input.

| Contract | Ciri translation | If not selected |
|---|---|---|
| `nixdesktop.startup` | `spawn-sh-at-startup` lines | nothing rendered |
| `nixdisplay.layouts.<name>` | typed `output {}` blocks | Ciri auto-detection |
| `nixdisplay.monitors.<name>` | identity and alias match blocks | only needed by identity layouts |
| `nixdesktop.sessions.<name>` | primary render device and denylist | no device restriction |
| `nixgpu.stableDevicePaths.devices` | stable `/dev/dri/by-path/*` values | only needed by a selected session |

Naming a layout, session, monitor, or device that cannot be resolved fails
evaluation. A missing sibling namespace is otherwise a silent and valid state.

### Output translation

`programs.ciri.outputs` is the manual, host-specific escape path.
`programs.ciri.layout` is the portable path: it names a neutral
`nixdisplay.layouts` entry and expands monitor identities and aliases into Ciri
output blocks. Counter-clockwise transforms pass through unchanged. Modeline
sync flags are quoted for KDL while their timing fields remain unchanged.

### Device restriction

Ciri's inherited backend currently expresses device selection through the
unstable `debug` keys `render-drm-device` and `ignore-drm-device`. The module
resolves neutral device names to stable paths before writing the config. Setting
`programs.ciri.session` therefore also requires `programs.ciri.package`; use
this flake's package so the version check describes the exact compositor that
will run.

## Raw escape hatches

Structured outputs and binds cover the validated surface. The following options
carry Ciri KDL verbatim for private choices or new upstream syntax:

- `extraOutputs`
- `extraStartup`
- `extraWindowRules`
- `extraBinds`
- `extraTopLevel`

## Validation

The flake checks:

- evaluate the Home Manager module instead of merely listing it;
- test startup translation in both composed and standalone states;
- test output, layout, monitor-alias, transform and device-path translation;
- feed a broad rendered fixture to the exact packaged Ciri validator;
- boot a nested-compositor VM and use only a newly proved Ciri IPC socket;
- boot a separate TTY/DRM VM and require the software-EGL fallback plus disabled
  dma-buf/DRM leasing before any host canary;
- reject retired public names in the repository source.

Run the full suite on the configured build service:

```console
nix flake check --all-systems
```

## Status

The public runtime and integration are complete only when the full GitHub Actions
suite is green. Publishing this repository does not activate Ciri on a host. A
private platform hub must select it explicitly after those VM gates pass.

## Licence

Outbound licence is `MIT OR Apache-2.0`. See `LICENSE-MIT` and `LICENSE-APACHE`; every source file carries `SPDX-License-Identifier: MIT OR Apache-2.0`.
