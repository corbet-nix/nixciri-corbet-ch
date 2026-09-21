# SPDX-License-Identifier: MIT OR Apache-2.0
# Boot an isolated NixOS VM, start a headless Weston parent, then run the exact
# packaged Ciri binary as a nested compositor. IPC is permitted only after the
# test has proved which new socket this compositor owns.
{ pkgs, nixosModule, ciriPackage }:
let
  config = pkgs.writeText "ciri-nested-vm.kdl" ''
    hotkey-overlay {
        skip-at-startup
    }
  '';
in
pkgs.testers.nixosTest {
  name = "nixciri-nested-runtime";

  nodes.machine = { ... }: {
    imports = [ nixosModule ];
    programs.ciri = {
      enable = true;
      package = ciriPackage;
    };
    environment.systemPackages = [
      pkgs.jq
      pkgs.weston
    ];
    virtualisation = {
      memorySize = 3072;
      cores = 2;
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")

    with subtest("the complete product is materialized"):
        machine.succeed("test -x ${ciriPackage}/bin/ciri")
        machine.succeed("test -f ${ciriPackage}/share/wayland-sessions/ciri.desktop")
        machine.succeed("test -f ${ciriPackage}/share/xdg-desktop-portal/ciri-portals.conf")
        machine.succeed("command -v xwayland-satellite")
        machine.succeed("test -x ${pkgs.xdg-desktop-portal-gnome}/libexec/xdg-desktop-portal-gnome")
        machine.succeed("test -x ${pkgs.xdg-desktop-portal-gtk}/libexec/xdg-desktop-portal-gtk")

    with subtest("the exact packaged binary accepts the fixture"):
        machine.succeed("install -d -m 0700 /run/ciri-validate")
        machine.succeed("XDG_RUNTIME_DIR=/run/ciri-validate ${ciriPackage}/bin/ciri validate -c ${config}")

    with subtest("a disposable parent compositor owns its socket"):
        machine.succeed("install -d -m 0700 /run/ciri-nested-vm")
        machine.succeed(
            "systemd-run --unit=weston-nested-vm "
            "--property=Environment=XDG_RUNTIME_DIR=/run/ciri-nested-vm "
            "${pkgs.weston}/bin/weston --backend=headless-backend.so "
            "--socket=wayland-parent --idle-time=0 --no-config"
        )
        machine.wait_until_succeeds("test -S /run/ciri-nested-vm/wayland-parent")
        machine.succeed(
            "find /run/ciri-nested-vm -maxdepth 1 -type s -name 'ciri.*.sock' "
            "-print | sort > /run/ciri-nested-before"
        )

    with subtest("the packaged compositor runs nested with software GL"):
        machine.succeed(
            "systemd-run --unit=ciri-nested-vm "
            "--property=Environment=XDG_RUNTIME_DIR=/run/ciri-nested-vm "
            "--property=Environment=WAYLAND_DISPLAY=wayland-parent "
            "--property=Environment=LIBGL_ALWAYS_SOFTWARE=1 "
            "${ciriPackage}/bin/ciri -c ${config}"
        )
        machine.wait_until_succeeds(
            "test $(find /run/ciri-nested-vm -maxdepth 1 -type s "
            "-name 'ciri.*.sock' | wc -l) -eq 1"
        )
        machine.succeed(
            "find /run/ciri-nested-vm -maxdepth 1 -type s -name 'ciri.*.sock' "
            "-print | sort | comm -13 /run/ciri-nested-before - "
            "> /run/ciri-nested-owned-sockets"
        )
        machine.succeed("test $(wc -l < /run/ciri-nested-owned-sockets) -eq 1")
        machine.succeed("test -S $(cat /run/ciri-nested-owned-sockets)")
        machine.succeed("systemctl is-active ciri-nested-vm.service")

    with subtest("IPC reaches only the proven nested compositor"):
        machine.succeed(
            "socket=$(cat /run/ciri-nested-owned-sockets); "
            "CIRI_SOCKET=$socket ${ciriPackage}/bin/ciri msg --json outputs "
            "| tee /run/ciri-nested-outputs.json "
            "| jq -e 'length == 1 and .winit.name == \"winit\"'"
        )

    machine.succeed("systemctl stop ciri-nested-vm.service weston-nested-vm.service")
  '';
}
