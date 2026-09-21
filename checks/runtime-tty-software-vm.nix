# SPDX-License-Identifier: MIT OR Apache-2.0
# Exercise Ciri's real TTY/DRM backend in a disposable NixOS VM. This is the
# fork-specific gate: LIBGL_ALWAYS_SOFTWARE must reach the exact packaged
# binary, the software-EGL fallback must initialize, and dma-buf/DRM leasing
# must be disabled before any live-host canary is considered.
{ pkgs, ciriPackage }:
let
  config = pkgs.writeText "ciri-tty-vm.kdl" ''
    hotkey-overlay {
        skip-at-startup
    }
  '';
in
pkgs.testers.nixosTest {
  name = "nixciri-tty-software-runtime";

  nodes.machine = { ... }: {
    boot.kernelModules = [ "virtio_gpu" ];
    hardware.graphics.enable = true;
    services.seatd.enable = true;

    users.users.ciri-test = {
      isNormalUser = true;
      uid = 1000;
      group = "users";
      extraGroups = [
        "input"
        "seat"
        "video"
        "render"
      ];
    };

    systemd.tmpfiles.rules = [
      "d /run/user/1000 0700 ciri-test users -"
    ];
    systemd.services."getty@tty1".enable = false;
    systemd.services."autovt@tty1".enable = false;

    systemd.services.ciri-tty-vm = {
      description = "Disposable Ciri TTY software-rendering test";
      after = [
        "seatd.service"
        "systemd-user-sessions.service"
      ];
      requires = [ "seatd.service" ];
      serviceConfig = {
        Type = "notify";
        User = "ciri-test";
        Group = "users";
        SupplementaryGroups = [
          "input"
          "seat"
          "video"
          "render"
        ];
        PAMName = "login";
        TTYPath = "/dev/tty1";
        StandardInput = "tty-force";
        StandardOutput = "journal";
        StandardError = "journal";
        TTYReset = true;
        TTYVHangup = true;
        UtmpIdentifier = "tty1";
        UtmpMode = "user";
        Environment = [
          "XDG_RUNTIME_DIR=/run/user/1000"
          "XDG_SESSION_TYPE=wayland"
          "XDG_SESSION_DESKTOP=ciri"
          "XDG_CURRENT_DESKTOP=ciri"
          "LIBSEAT_BACKEND=seatd"
          "LIBGL_ALWAYS_SOFTWARE=1"
          "RUST_BACKTRACE=1"
        ];
        ExecStart = "${ciriPackage}/bin/ciri --session -c ${config}";
      };
    };

    environment.systemPackages = [
      ciriPackage
      pkgs.jq
      pkgs.mesa-demos
    ];

    virtualisation = {
      memorySize = 4096;
      cores = 4;
      qemu.options = [ "-device virtio-vga" ];
    };
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("seatd.service")

    with subtest("the VM has an isolated DRM device and software EGL"):
        machine.succeed("test -c /dev/dri/card0")
        machine.succeed("LIBGL_ALWAYS_SOFTWARE=1 eglinfo -B -p surfaceless 2>&1 | tee /run/egl-info")
        machine.succeed("grep -Ei 'llvmpipe|softpipe|software' /run/egl-info")
        machine.succeed(
            "find /run/user/1000 -maxdepth 1 -type s -name 'ciri.*.sock' "
            "-print | sort > /run/ciri-tty-before"
        )

    with subtest("the exact packaged compositor takes the TTY software path"):
        machine.succeed("systemctl start --no-block ciri-tty-vm.service")
        machine.wait_until_succeeds(
            "systemctl is-active --quiet ciri-tty-vm.service "
            "|| systemctl is-failed --quiet ciri-tty-vm.service",
            timeout=60,
        )
        machine.succeed("systemctl is-active --quiet ciri-tty-vm.service")
        # PAM moves the compositor into the user's session cgroup, so journald
        # does not reliably retain ciri-tty-vm.service as `_SYSTEMD_UNIT` even
        # though systemd still owns and supervises the process. This disposable
        # VM runs exactly one Ciri process; query the boot journal so the gate
        # follows that process across the PAM cgroup transition.
        machine.wait_until_succeeds(
            "journalctl -b -o cat --no-pager | "
            "sed -r 's/\\x1B\\[[0-9;]*[mK]//g' | "
            "grep -F 'using software EGL renderer as a fallback'",
            timeout=60,
        )
        machine.succeed(
            "journalctl -b -o cat --no-pager | "
            "sed -r 's/\\x1B\\[[0-9;]*[mK]//g' | "
            "grep -F 'software rendering; disabling dma-buf protocol and DRM leasing'"
        )
        machine.wait_until_succeeds(
            "test $(find /run/user/1000 -maxdepth 1 -type s "
            "-name 'ciri.*.sock' | wc -l) -eq 1 "
            "|| systemctl is-failed --quiet ciri-tty-vm.service",
            timeout=60,
        )
        machine.succeed("systemctl is-active --quiet ciri-tty-vm.service")
        machine.fail(
            "journalctl -b -o cat --no-pager | "
            "grep -F 'Error::NoDevice'"
        )
        machine.succeed(
            "find /run/user/1000 -maxdepth 1 -type s -name 'ciri.*.sock' "
            "-print | sort | comm -13 /run/ciri-tty-before - "
            "> /run/ciri-tty-owned-sockets"
        )
        machine.succeed("test $(wc -l < /run/ciri-tty-owned-sockets) -eq 1")
        machine.succeed("test -S $(cat /run/ciri-tty-owned-sockets)")

    with subtest("IPC reaches only the proven TTY compositor"):
        machine.succeed(
            "socket=$(cat /run/ciri-tty-owned-sockets); "
            "sudo -u ciri-test env XDG_RUNTIME_DIR=/run/user/1000 CIRI_SOCKET=$socket "
            "${ciriPackage}/bin/ciri msg --json outputs "
            "| tee /run/ciri-tty-outputs.json | jq -e 'length >= 1'"
        )

    machine.succeed("systemctl stop ciri-tty-vm.service")
  '';
}
