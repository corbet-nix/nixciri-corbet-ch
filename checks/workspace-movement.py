"""Real-client regression for declared workspace traversal in the isolated VM."""

import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time


socket_path, expected_pid, names_path, wayland_path, foot_binary, sleep_binary = sys.argv[1:]
expected_pid = int(expected_pid)
with open(names_path) as source:
    names = json.load(source)

# The client must connect to the same disposable compositor as the IPC checks.
with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
    connection.connect(wayland_path)
    peer = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    assert peer[:2] == (expected_pid, os.getuid()), peer
client_environment = dict(os.environ, WAYLAND_DISPLAY=wayland_path)


def request(message):
    # Never use compositor discovery or a CLI's socket fallback for test IPC.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(5)
        connection.connect(socket_path)
        pid, uid, _ = struct.unpack(
            "3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
        )
        assert pid == expected_pid and uid == os.getuid(), (pid, uid)
        connection.sendall((json.dumps(message) + "\n").encode())
        with connection.makefile("r") as response:
            reply = json.loads(response.readline())
        assert "Ok" in reply, reply
        return reply["Ok"]


def action(name, **arguments):
    return request({"Action": {name: arguments}})


def wait_for(predicate):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("timed out waiting for compositor state")


def workspaces():
    return request("Workspaces")["Workspaces"]


def windows():
    return request("Windows")["Windows"]


def focused_workspace(name):
    return any(w["name"] == name and w["is_focused"] for w in workspaces())


def window_on(window_id, name):
    workspace_id = next(w["id"] for w in workspaces() if w["name"] == name)
    return any(w["id"] == window_id and w["workspace_id"] == workspace_id for w in windows())


def assert_names_persist():
    named = sorted((w for w in workspaces() if w["name"] is not None), key=lambda w: w["idx"])
    assert [w["name"] for w in named] == names, named
    assert all(w["output"] == "winit" for w in named), named


assert_names_persist()
assert windows() == []
cases = 0
for group in [names[i:i + 3] for i in range(0, len(names), 3)]:
    for descending in (False, True):
        route = list(reversed(group)) if descending else group
        action("FocusWorkspace", reference={"Name": route[0]})
        wait_for(lambda: focused_workspace(route[0]))
        title = f"workspace-traversal-{cases}"
        with tempfile.TemporaryFile(mode="w+") as client_log:
            client = subprocess.Popen(
                [foot_binary, "--config=/dev/null", f"--title={title}", sleep_binary, "300"],
                env=client_environment, stdout=client_log, stderr=subprocess.STDOUT,
            )
            try:
                def mapped_window():
                    assert client.poll() is None, f"client exited with {client.returncode}"
                    return next((w for w in windows() if w["title"] == title), None)
                window = wait_for(mapped_window)
                window_id = window["id"]
                assert window_on(window_id, route[0])
                command = "MoveWindowUpOrToWorkspaceUp" if descending else "MoveWindowDownOrToWorkspaceDown"
                for destination in route[1:]:
                    action(command)
                    wait_for(lambda: window_on(window_id, destination))
                    assert focused_workspace(destination)
                    assert_names_persist()
                # Sparse numeric names must not be conflated with changing indices.
                action("MoveWindowToWorkspace", window_id=window_id, reference={"Name": route[0]}, focus=True)
                wait_for(lambda: window_on(window_id, route[0]))
                action("CloseWindow")
                wait_for(lambda: not windows())
            except Exception:
                client_log.seek(0)
                print(client_log.read(), file=sys.stderr)
                raise
            finally:
                if client.poll() is None:
                    client.terminate()
                try:
                    client.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    client.kill()
                    client.wait(timeout=5)
            assert_names_persist()
        cases += 1
        print(f"PASS {command}: {route}", flush=True)

print(f"{cases} movement cases passed; all declared empty slots persist", flush=True)
