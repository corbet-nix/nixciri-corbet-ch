# SPDX-License-Identifier: MIT OR Apache-2.0
{
  description = "nixciri — declarative Ciri packaging and desktop integration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # The runtime fork is a separate public product and the only compositor
    # source this integration packages. flake.lock makes that boundary exact.
    ciri = {
      url = "github:corbet-foss/ciri";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # nixhost IS an input, for exactly one thing: `lib.probeFact`/`lib.collectProbes`
    # (github:corbet-nix/nixhost-corbet-ch, `lib/facts.nix`) -- the shared, plain-function fix
    # for the cross-namespace defensive-read defect class this module's own reads of
    # `nixdisplay.layouts`/`nixdisplay.monitors`/`nixdesktop.sessions` AND
    # `nixgpu.stableDevicePaths.devices` lean on (see nixhost's own `lib/facts.nix` header, and
    # nixscroll's `home/scroll.nix`, which took this same input first). `probeFact`/
    # `collectProbes` are closed over as plain function arguments (below), never `_module.args`,
    # so a consumer importing `homeManagerModules.ciri` sees an ordinary module function and
    # never needs to know `nixhost` exists. Note this is a READ, not an `imports`: nixdisplay,
    # nixdesktop, and nixgpu are not flake inputs here (see README's contract table for
    # the full table) -- `nixhost` supplies only the probing MECHANISM both reads share. This is
    # `nixdesktop.startup` remains a defensive, zero-flake-dependency read. The probe mechanism
    # is used for the assertable output/layout/session seams.
    nixhost = {
      url = "github:corbet-nix/nixhost-corbet-ch";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixhost, ciri }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

      # `probeFact`/`collectProbes` closed over here, before the module system ever sees the
      # result -- see the `nixhost` input comment above. The exported value is a plain
      # home-manager module function taking the usual `{ lib, config, ... }`; nothing about
      # consuming it changes.
      ciriModule = import ./home/ciri.nix { inherit (nixhost.lib) probeFact collectProbes; };
      descriptorFor = import ./lib/compositor-descriptor.nix;
    in
    {
      # ── PACKAGING ───────────────────────────────────────────────────────────────────────────
      # Ciri already carries the Nix build recipe in its runtime repo. This integration adds a
      # narrow Arch-safe Mesa wrapper to the compositor executable only; it neither forces the
      # software renderer nor wraps the IPC client. The launcher descriptor below maps the
      # compositor-neutral `software` intent to LIBGL_ALWAYS_SOFTWARE.
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          mesaEnvironment = {
            eglVendor = "${pkgs.mesa}/share/glvnd/egl_vendor.d/50_mesa.json";
            libglDrivers = "${pkgs.mesa}/lib/dri";
          };
          ciriPackage = ciri.packages.${system}.ciri.overrideAttrs (old: {
            nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.makeWrapper ];
            postFixup = (old.postFixup or "") + ''
              wrapProgram "$out/bin/ciri" \
                --set-default __EGL_VENDOR_LIBRARY_FILENAMES "${mesaEnvironment.eglVendor}" \
                --set-default LIBGL_DRIVERS_PATH "${mesaEnvironment.libglDrivers}"
            '';
            passthru = (old.passthru or { }) // {
              nixciriMesaEnvironment = mesaEnvironment;
            };
          });
        in
        {
          ciri = ciriPackage;
          default = ciriPackage;
        });

      nixosModules.ciri = import ./modules/nixos.nix { inherit self descriptorFor; };
      nixosModules.default = self.nixosModules.ciri;

      systemManagerModules.ciri = import ./modules/system-manager.nix { inherit self descriptorFor; };
      systemManagerModules.default = self.systemManagerModules.ciri;

      # ── CONFIG GENERATION ─────────────────────────────────────────────────────────────────
      # A home-manager module that writes one real dotfile and installs no package.
      #
      # `homeManagerModules`, not `homeModules`: home-manager upstream has moved to the
      # shorter name, but every other project in this family (nixdesktop, nixarch, nixsh,
      # nixremote) exports `homeManagerModules`, and a consumer importing several of them at
      # once should not have to remember which one is spelled differently. Family consistency
      # wins over upstream fashion.
      homeManagerModules = {
        ciri = ciriModule;

        # Ciri is the only home-manager module this project exports.
        default = ciriModule;
      };

      # ── CHECKS ────────────────────────────────────────────────────────────────────────────
      # `nix flake check` does NOT evaluate `homeManagerModules` — it lists them as unchecked and
      # moves on. Since that class is the only thing this repo ships, a green `flake check` here
      # used to prove nothing whatsoever about the module. These checks close that gap by
      # evaluating home/ciri.nix for real against a minimal home-manager stub, and (output-accepted)
      # by running its rendered KDL past the upstream grammar validator.
      checks = forAllSystems (system: {
        startup-contract = import ./checks/startup-contract.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit ciriModule;
        };

        # Scoped to the structured-output/layout/session seam this session's work added: a
        # generated block renders syntactically sane KDL, transform passes through untouched,
        # identity matchers with spaces are quoted, the denylist covers every denied device, and
        # every alias variant of an identity-matched monitor gets its own block. See the file's
        # own header for why each of these has a SILENT failure mode that makes it worth a check.
        output-contract = import ./checks/output-contract.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit ciriModule;
        };

        no-retired-names = import ./checks/no-retired-names.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          src = self;
        };

        arch-integration = import ./checks/arch-integration.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          systemManagerModule = self.systemManagerModules.ciri;
        };
        nixos-integration = import ./checks/nixos-integration.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          nixosModule = self.nixosModules.ciri;
        };
      }
      # `output-accepted` is NOT part of the uniform `forAllSystems` set above, deliberately —
      # narrowed to x86_64-linux only, the one system this CI actually runs on and can build a
      # real binary for.
      #
      # This check runs the upstream parser inherited by Ciri against this module's rendered
      # output (see its own header) — it is the one check in this repo that a
      # `pkgs.emptyFile` fixed-output marker CANNOT paper over, because there is a genuine
      # foreign-arch BUILD to do here (the fixture `config.kdl` written via `pkgs.writeText`,
      # and the validator itself) and a genuine foreign-arch binary to run inside
      # `pkgs.runCommand`), neither of which this repo has an aarch64 builder or emulation for.
      # Measured: `nix flake check --all-systems` failed exactly here —
      # `checks.aarch64-linux.output-accepted` — with "Cannot build
      # '.../niri-fixture-config.kdl.drv': Reason: platform mismatch, Required system:
      # aarch64-linux, Current system: x86_64-linux" — a `pkgs.emptyFile` swap would have made
      # that failure disappear by silently skipping the one check whose entire point is asking a
      # real binary a real question, on the one arch nothing here can ask it on. Narrowing to
      # x86_64-linux says exactly that out loud instead: this check has no aarch64 coverage,
      # rather than pretending it passed. `startup-contract`/`output-contract` above stay on
      # every declared system unchanged — both decide everything at Nix EVALUATION time (no
      # binary of any arch ever runs), which is exactly the shape `pkgs.emptyFile` fixes for,
      # and is why they keep using it (see each file's own closing comment).
      // nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
        output-accepted = import ./checks/output-accepted.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          upstreamValidator = self.packages.${system}.ciri;
          inherit ciriModule;
        };

        runtime-nested-vm = import ./checks/runtime-nested-vm.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          nixosModule = self.nixosModules.ciri;
          ciriPackage = self.packages.${system}.ciri;
        };

        runtime-tty-software-vm = import ./checks/runtime-tty-software-vm.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          ciriPackage = self.packages.${system}.ciri;
        };
      });

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixpkgs-fmt);
    };
}
