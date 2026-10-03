#!/usr/bin/python3
"""Opt-in, container-owned graphics lifecycle. Never launches Chrome."""
import base64
import ctypes
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.request

STOP = threading.Event()


def log(message):
    print(f"dsh-graphics: {message}", file=sys.stderr, flush=True)


def resolution(value):
    if not re.fullmatch(r"[0-9]{3,4}x[0-9]{3,4}", value):
        raise ValueError("resolution must be WIDTHxHEIGHT")
    width, height = map(int, value.split("x"))
    if not (640 <= width <= 3840 and 360 <= height <= 2160
            and width % 8 == 0 and height % 2 == 0):
        raise ValueError("resolution must fit 640x360..3840x2160, width aligned to 8, height to 2")
    return width, height


def config(environ):
    display = environ.get("DSH_GRAPHICS_DISPLAY", ":99")
    if not re.fullmatch(r":[0-9]{1,5}", display) or int(display[1:]) > 65535:
        raise ValueError("DSH_GRAPHICS_DISPLAY must be :NUMBER (0..65535)")
    # Normalize so :099 and :99 cannot acquire different runtime directories.
    display = f":{int(display[1:])}"
    initial = resolution(environ.get("DSH_GRAPHICS_RESOLUTION", "1280x720"))
    maximum = resolution(environ.get("DSH_GRAPHICS_MAX_RESOLUTION", "3840x2160"))
    if any(a > b for a, b in zip(initial, maximum)):
        raise ValueError("initial resolution exceeds framebuffer ceiling")
    port = environ.get("DSH_GRAPHICS_PORT", "8080")
    if not re.fullmatch(r"[0-9]{4,5}", port) or not 1024 <= int(port) <= 65535 or int(port) == 3080:
        raise ValueError("DSH_GRAPHICS_PORT must be 1024..65535, excluding DSH port 3080")
    secret_file = environ.get("DSH_GRAPHICS_PASSWORD_FILE", "")
    if not os.path.isabs(secret_file):
        raise ValueError("DSH_GRAPHICS_PASSWORD_FILE must name an absolute readable secret file")
    with open(secret_file, encoding="utf-8") as secret:
        password = secret.read(4098).removesuffix("\n")
    if not 12 <= len(password) <= 4096 or any(c in password for c in "\r\n\0"):
        raise ValueError("graphics password must be 12..4096 characters on one line")
    root = Path(f"/tmp/dsh-graphics-{display[1:]}")
    return display, initial, maximum, int(port), password, root


def command(argv, env, timeout=3, input_text=None):
    return subprocess.run(argv, env=env, check=True, capture_output=True,
                          text=True, timeout=timeout, input=input_text).stdout


def geometry(env):
    output = command(["xdpyinfo"], env)
    match = re.search(r"dimensions:\s+(\d+)x(\d+) pixels", output)
    if not match:
        raise RuntimeError("X server did not report display dimensions")
    return tuple(map(int, match.groups()))


def audio_ready(env):
    command(["pactl", "info"], env)
    return "output.monitor" in command(["pactl", "list", "short", "sources"], env)


def viewer_ready(port, password):
    token = base64.b64encode(f"dsh:{password}".encode()).decode()
    request = urllib.request.Request(f"http://127.0.0.1:{port}/",
                                     headers={"Authorization": f"Basic {token}"})
    # Never honor proxy variables for internal readiness or send credentials to a proxy.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(request, timeout=2) as response:
        return response.status == 200 and b"<html" in response.read(16384).lower()


def streamer_args(port, root):
    locked_off = ("enable-dual-mode", "second-screen", "microphone-enabled",
                  "webcam-enabled", "command-enabled", "enable-binary-clipboard",
                  "gamepad-enabled", "printing-enabled", "enable-sharing",
                  "enable-shared", "enable-collab", "enable-player2", "enable-player3",
                  "enable-player4", "publish-input-devices", "video-fullcolor")
    return ["selkies", "--addr=127.0.0.1", f"--port={port}", "--mode=websockets",
            "--enable-https=false", "--enable-basic-auth=true", "--basic-auth-user=dsh",
            "--encoder=h264enc", "--use-cpu=true|locked", "--framerate=30-30",
            "--enable-resize=true", "--audio-device-name=output.monitor",
            "--file-transfers=none", "--enable-clipboard=false", "--uinput-gamepad=false",
            f"--file-manager-path={root}/files", f"--print-spool-path={root}/print",
            *[f"--{key}=false|locked" for key in locked_off]]


def descendants():
    """Owned descendants, including adopted double-forks after subreaper setup."""
    parents = {}
    for entry in Path("/proc").iterdir():
        if entry.name.isdigit():
            try:
                status = (entry / "status").read_text()
                parents[int(entry.name)] = int(re.search(r"^PPid:\s+(\d+)", status, re.M)[1])
            except (OSError, TypeError):
                pass
    owned = {os.getpid()}
    while True:
        more = {pid for pid, parent in parents.items() if parent in owned} - owned
        if not more:
            return owned - {os.getpid()}
        owned |= more


class Runtime:
    def __init__(self):
        self.children = []

    def spawn(self, label, argv, env):
        child = subprocess.Popen(argv, env=env, start_new_session=True)
        self.children.append((label, child))
        log(f"{label} pid={child.pid}")
        return child

    def alive(self):
        for label, child in self.children:
            if child.poll() is not None:
                raise RuntimeError(f"{label} exited unexpectedly (status {child.returncode})")

    def wait_ready(self, label, probe):
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not STOP.is_set():
            self.alive()
            try:
                if probe():
                    log(f"{label} ready")
                    return
            except (OSError, subprocess.SubprocessError, RuntimeError):
                pass
            STOP.wait(0.2)
        if STOP.is_set():
            raise InterruptedError("shutdown requested during readiness")
        raise RuntimeError(f"{label} readiness timed out")

    def close(self):
        # DSH was started last: drain it while its display/audio are still alive.
        for label, child in reversed(self.children):
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=7 if label == "dsh" else 2)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass  # Child exited between wait timeout and escalation.
                child.wait(timeout=2)
        self.children.clear()
        # Services may double-fork/create new groups, including during shutdown.
        # Refresh the owned tree and bound reaping instead of blocking indefinitely.
        deadline = time.monotonic() + 2
        while True:
            for pid in descendants():
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                while os.waitpid(-1, os.WNOHANG)[0]:
                    pass
            except ChildProcessError:
                return
            if time.monotonic() >= deadline:
                raise RuntimeError("owned descendants did not exit after SIGKILL")
            time.sleep(0.02)


def run(arguments):
    if os.geteuid() == 0:
        raise RuntimeError("graphics must run as a non-root runtime UID")
    display, initial, maximum, port, password, root = config(os.environ)
    if arguments == ["--check-graphics"]:
        with open(root / "environment.json", encoding="utf-8") as manifest:
            env = {**os.environ, **json.load(manifest)["environment"]}
        if not audio_ready(env) or not viewer_ready(port, password):
            raise RuntimeError("graphics readiness check failed")
        log(f"ready: display={display} geometry={geometry(env)} viewer=127.0.0.1:{port}")
        return 0
    for tool in ("Xvfb", "xauth", "xdpyinfo", "xprop", "selkies-resize", "pulseaudio", "pactl", "openbox", "selkies", "dsh"):
        if not shutil.which(tool):
            raise RuntimeError(f"missing {tool}; graphics requires the Plus image")
    if Path(f"/tmp/.X11-unix/X{display[1:]}").exists() or Path(f"/tmp/.X{display[1:]}-lock").exists():
        raise RuntimeError(f"display {display} already exists; refusing to take ownership")
    os.umask(0o077)
    # Exclusive mkdir: never attach to or delete a foreign/stale runtime directory.
    root.mkdir(mode=0o700)
    runtime = Runtime()
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            raise OSError(ctypes.get_errno(), "cannot enable graphics subreaper")
        for directory in ("home", "pulse", "config", "cache", "state"):
            (root / directory).mkdir(mode=0o700)
        environment = {"DISPLAY": display, "XAUTHORITY": str(root / "Xauthority"),
                       "XDG_RUNTIME_DIR": str(root), "HOME": str(root / "home"),
                       "XDG_CONFIG_HOME": str(root / "config"), "XDG_CACHE_HOME": str(root / "cache"),
                       "XDG_STATE_HOME": str(root / "state"), "PULSE_RUNTIME_PATH": str(root / "pulse"),
                       "PULSE_STATE_PATH": str(root / "state"), "PULSE_COOKIE": str(root / "pulse-cookie"),
                       "PULSE_SERVER": f"unix:{root}/pulse/native"}
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("SELKIES_", "PIXELFLUX_", "PCMFLUX_"))
               and key not in ("LD_PRELOAD", "CUSTOM_WS_PORT", "CUSTOM_USER", "USERNAME",
                               "PASSWORD", "PASSWD", "VIEWONLY_PASSWORD", "SUBFOLDER",
                               "DRI_NODE", "DRINODE", "AUTO_GPU", "FILE_MANAGER_PATH",
                               "WATERMARK_PNG", "WATERMARK_LOCATION", "XCURSOR_SIZE")}
        env.update(environment)
        env.update(USER=f"dsh-{os.getuid()}", LOGNAME=f"dsh-{os.getuid()}")
        (root / "Xauthority").touch(mode=0o600)
        command(["xauth", "-f", env["XAUTHORITY"], "source", "-"], env,
                input_text=f"add {display} MIT-MAGIC-COOKIE-1 {secrets.token_hex(16)}\n")
        runtime.spawn("Xvfb", ["Xvfb", display, "-screen", "0", f"{maximum[0]}x{maximum[1]}x24",
                              "-auth", env["XAUTHORITY"], "-nolisten", "tcp", "-noreset",
                              "-s", "0", "-dpms", "+extension", "RANDR", "+extension", "XTEST"], env)
        runtime.wait_ready("X11 authenticated handshake", lambda: geometry(env) == maximum)
        command(["selkies-resize", f"{initial[0]}x{initial[1]}"], env, timeout=15)
        if geometry(env) != initial:
            raise RuntimeError("initial resize did not realize requested geometry")
        pulse_config = root / "pulse.pa"
        pulse_config.write_text(f"load-module module-native-protocol-unix socket={root}/pulse/native "
                                f"auth-cookie={root}/pulse-cookie auth-anonymous=no\n"
                                "load-module module-null-sink sink_name=output rate=48000 channels=2\n"
                                "set-default-sink output\n")
        runtime.spawn("PulseAudio", ["pulseaudio", "--daemonize=no", "--use-pid-file=no",
                                    "--exit-idle-time=-1", "--disable-shm=yes", "--high-priority=no",
                                    "--realtime=no", "--log-target=stderr", "-n", "-F", str(pulse_config)], env)
        runtime.wait_ready("PulseAudio output.monitor", lambda: audio_ready(env))
        runtime.spawn("Openbox", ["openbox", "--sm-disable", "--config-file",
                                 "/opt/deepseek-harness/graphics/openbox.xml"], env)
        runtime.wait_ready("Openbox window ownership", lambda: bool(re.search(
            r"window id # 0x[0-9a-f]+", command(["xprop", "-root", "_NET_SUPPORTING_WM_CHECK"], env))))
        env["SELKIES_BASIC_AUTH_PASSWORD"] = password
        runtime.spawn("Selkies", streamer_args(port, root), env)
        runtime.wait_ready("authenticated viewer HTTP (not media)", lambda: viewer_ready(port, password))
        manifest = {"environment": environment, "viewer_url": f"http://127.0.0.1:{port}/",
                    "websocket_url": f"ws://127.0.0.1:{port}/api/websockets",
                    "maximum_resolution": list(maximum), "pids": {label: child.pid for label, child in runtime.children}}
        (root / "environment.json").write_text(json.dumps(manifest) + "\n")
        log(f"graphics ready; Chrome owner must read {root}/environment.json")
        dsh_env = {**os.environ, "DSH_GRAPHICS_ENV_FILE": str(root / "environment.json")}
        dsh = runtime.spawn("dsh", ["dsh", *arguments], dsh_env)
        while not STOP.wait(0.2):
            if dsh.poll() is not None:
                return dsh.returncode if dsh.returncode >= 0 else 128 - dsh.returncode
            runtime.alive()
        return 0
    finally:
        runtime.close()
        # Verified owned path: created exclusively above, never a reused mount/tree.
        if root.parent != Path("/tmp") or root.name != f"dsh-graphics-{display[1:]}":
            raise RuntimeError("refusing cleanup outside owned graphics runtime")
        shutil.rmtree(root)
        log("owned graphics processes reaped; private runtime removed")


if __name__ == "__main__":
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, lambda *_: STOP.set())
    try:
        sys.exit(run(sys.argv[1:]))
    except InterruptedError:
        sys.exit(0)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        log(str(error))
        sys.exit(1)
