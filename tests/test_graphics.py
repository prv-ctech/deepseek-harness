"""Local regressions; mocks do not constitute display/media acceptance."""
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("graphics", ROOT / "graphics/runtime.py")
graphics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(graphics)


class GraphicsTests(unittest.TestCase):
    def setUp(self):
        graphics.STOP.clear()
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.env = {}

    def test_smoke_native_cache_mount_is_executable(self):
        mounts = {}
        for line in (ROOT / "scripts/graphics-smoke.sh").read_text().splitlines():
            if line.strip().startswith("--tmpfs "):
                target, options = line.split()[1].split(":", 1)
                mounts[target] = set(options.split(","))
        self.assertIn("exec", mounts["/home/node/.dsh"])
        self.assertNotIn("noexec", mounts["/home/node/.dsh"])
        for target in ("/tmp", "/workspace"):
            self.assertIn("noexec", mounts[target])
            self.assertNotIn("exec", mounts[target])

    def test_smoke_failure_reports_before_cleanup(self):
        docker = Path(self.temp.name) / "docker"
        docker.write_text('''#!/bin/sh
case "$1 $2" in
  "container inspect") exit 1 ;;
  "run -d") exit 42 ;;
  "inspect --format") echo "diagnostic container state" ;;
  "logs --tail") echo "diagnostic container logs"; echo logs >> "$MOCK_DOCKER_TRACE" ;;
  "rm -f") echo cleanup >> "$MOCK_DOCKER_TRACE" ;;
esac
''')
        docker.chmod(0o755)
        trace = Path(self.temp.name) / "trace"
        result = subprocess.run(["bash", str(ROOT / "scripts/graphics-smoke.sh"), "test-image"],
                                env={**os.environ, "PATH": f"{self.temp.name}:{os.environ['PATH']}",
                                     "MOCK_DOCKER_TRACE": str(trace)},
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 42)
        self.assertRegex(result.stderr, r"graphics smoke failed at line \d+ \(exit 42\)")
        self.assertIn("diagnostic container state", result.stderr)
        self.assertIn("diagnostic container logs", result.stderr)
        self.assertEqual(trace.read_text().splitlines(), ["logs", "logs", "logs", "cleanup"])

    def test_config_validation(self):
        self.assertEqual(graphics.config(self.env)[:4], (":99", (1280, 720), (3840, 2160), 8080))
        self.assertEqual(graphics.config({**self.env, "DSH_GRAPHICS_DISPLAY": ":099"})[0], ":99")
        for key, value in (("DSH_GRAPHICS_DISPLAY", ":1;evil"), ("DSH_GRAPHICS_DISPLAY", ":65536"),
                           ("DSH_GRAPHICS_RESOLUTION", "1279x721"), ("DSH_GRAPHICS_RESOLUTION", "9999x9999"),
                           ("DSH_GRAPHICS_PORT", "3080"), ("DSH_GRAPHICS_PORT", "80"),
                           ("DSH_GRAPHICS_MAX_RESOLUTION", "640x360")):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                graphics.config({**self.env, key: value})

    def test_security_settings_are_locked(self):
        args = graphics.streamer_args(8080, Path("/tmp/example"))
        for flag in ("--addr=127.0.0.1", "--mode=websockets", "--enable-basic-auth=false|locked",
                     "--use-cpu=true|locked", "--video-fullcolor=false|locked", "--encoder=h264enc",
                     "--enable-dual-mode=false|locked", "--microphone-enabled=false|locked",
                     "--webcam-enabled=false|locked", "--command-enabled=false|locked",
                     "--file-transfers=none", "--enable-clipboard=false", "--enable-sharing=false|locked"):
            self.assertIn(flag, args)
        self.assertFalse(any("password" in flag for flag in args))
        self.assertNotIn("--public", args)

    def test_viewer_readiness_is_loopback_without_extra_login_or_proxy(self):
        opener = unittest.mock.MagicMock()
        response = opener.open.return_value.__enter__.return_value
        response.status = 200
        response.read.return_value = b"<html>viewer</html>"
        with patch.object(graphics.urllib.request, "ProxyHandler") as proxy, \
                patch.object(graphics.urllib.request, "build_opener", return_value=opener):
            self.assertTrue(graphics.viewer_ready(8080))
            proxy.assert_called_once_with({})
            opener.open.assert_called_once_with("http://127.0.0.1:8080/", timeout=2)

    def test_readiness_checks_real_geometry_not_helper_exit(self):
        with patch.object(graphics, "command", return_value="dimensions: 1280x720 pixels (1x1 millimeters)"):
            self.assertEqual(graphics.geometry({}), (1280, 720))
        with patch.object(graphics, "command", return_value="no display geometry"):
            with self.assertRaises(RuntimeError):
                graphics.geometry({})
        runtime = graphics.Runtime()
        dead = unittest.mock.Mock()
        dead.poll.return_value = 0
        dead.returncode = 0
        runtime.children.append(("Selkies", dead))
        with self.assertRaisesRegex(RuntimeError, "Selkies exited unexpectedly"):
            runtime.wait_ready("viewer", lambda: True)

    def test_shutdown_interrupts_readiness_without_success_claim(self):
        graphics.STOP.set()
        with self.assertRaises(InterruptedError):
            graphics.Runtime().wait_ready("X11", lambda: False)

    def test_runtime_manifest_and_dsh_environment(self):
        # Unique reserved high display; run() creates it exclusively and owns cleanup.
        self.env.update(DSH_GRAPHICS_DISPLAY=":64321", DISPLAY=":2",
                        SELKIES_MASTER_TOKEN="must-not-reach-streamer", PIXELFLUX_CU="9500",
                        SELKIES_ENABLE_BASIC_AUTH="true", SELKIES_BASIC_AUTH_PASSWORD="unused-parent-value",
                        VIEWONLY_PASSWORD="unintended-second-password", SUBFOLDER="unexpected-prefix")
        captured = []
        class Child:
            pid = 10000000
            returncode = 0
            def poll(self):
                return 0 if self.is_dsh else None
        def spawn(argv, **kwargs):
            child = Child()
            child.is_dsh = argv[0] == "dsh"
            captured.append((argv, kwargs["env"]))
            if child.is_dsh:
                data = json.loads(Path(kwargs["env"]["DSH_GRAPHICS_ENV_FILE"]).read_text())
                self.assertEqual(data["environment"]["DISPLAY"], ":64321")
                self.assertNotIn("password", json.dumps(data))
            return child
        with patch.dict(os.environ, self.env, clear=True), patch.object(os, "geteuid", return_value=1234), \
                patch.object(graphics.shutil, "which", return_value="/usr/bin/tool"), \
                patch.object(graphics, "command", return_value="window id # 0x123") as commands, \
                patch.object(graphics, "geometry", side_effect=[(3840, 2160), (1280, 720)]), \
                patch.object(graphics, "audio_ready", return_value=True), \
                patch.object(graphics, "viewer_ready", return_value=True), \
                patch.object(graphics.subprocess, "Popen", side_effect=spawn), \
                patch.object(graphics.Runtime, "close") as close:
            self.assertEqual(graphics.run(["web", "--port", "3080"]), 0)
            close.assert_called_once()
            xauth = commands.call_args_list[0]
            self.assertEqual(xauth.args[0][-2:], ["source", "-"])
            self.assertRegex(xauth.kwargs["input_text"], r"^add :64321 MIT-MAGIC-COOKIE-1 [0-9a-f]{32}\n$")
        dsh_args, dsh_env = captured[-1]
        self.assertEqual(dsh_args, ["dsh", "web", "--port", "3080"])
        self.assertEqual(dsh_env["DISPLAY"], ":2")  # Not globally forced to graphics display.
        self.assertFalse(any("chrome" in argv[0] for argv, _ in captured))
        for _, env in captured[:-1]:
            self.assertNotIn("SELKIES_MASTER_TOKEN", env)
            self.assertNotIn("SELKIES_ENABLE_BASIC_AUTH", env)
            self.assertNotIn("SELKIES_BASIC_AUTH_PASSWORD", env)
            self.assertNotIn("PIXELFLUX_CU", env)
            self.assertNotIn("VIEWONLY_PASSWORD", env)
            self.assertNotIn("SUBFOLDER", env)
        self.assertEqual(dsh_env["VIEWONLY_PASSWORD"], "unintended-second-password")
        self.assertFalse(Path("/tmp/dsh-graphics-64321").exists())

    def test_partial_startup_failure_cleans_runtime_without_dsh(self):
        self.env["DSH_GRAPHICS_DISPLAY"] = ":64322"
        child = unittest.mock.Mock(pid=10000000)
        child.poll.return_value = None
        with patch.dict(os.environ, self.env, clear=True), patch.object(os, "geteuid", return_value=1234), \
                patch.object(graphics.shutil, "which", return_value="/usr/bin/tool"), \
                patch.object(graphics, "command", return_value=""), \
                patch.object(graphics, "geometry", side_effect=[(3840, 2160), (1280, 720)]), \
                patch.object(graphics.subprocess, "Popen", side_effect=[child, OSError("audio spawn failed")]) as spawn, \
                patch.object(graphics.Runtime, "close") as close:
            with self.assertRaisesRegex(OSError, "audio spawn failed"):
                graphics.run(["web"])
            close.assert_called_once()
            self.assertEqual([call.args[0][0] for call in spawn.call_args_list], ["Xvfb", "pulseaudio"])
        self.assertFalse(Path("/tmp/dsh-graphics-64322").exists())

    def test_shutdown_reaps_detached_descendant(self):
        libc = ctypes.CDLL(None, use_errno=True)
        self.assertEqual(libc.prctl(36, 1, 0, 0, 0), 0)
        pidfile = Path(self.temp.name) / "grandchild"
        code = ("import os,time,pathlib,signal; signal.signal(signal.SIGTERM,signal.SIG_IGN); pid=os.fork(); "
                f"\nif pid==0:\n os.setsid(); pathlib.Path({str(pidfile)!r}).write_text(str(os.getpid()))\n"
                "time.sleep(30)\n")
        runtime = graphics.Runtime()
        runtime.spawn("test", ["python3", "-c", code], os.environ.copy())
        try:
            deadline = time.monotonic() + 3
            while not pidfile.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(pidfile.exists())
            pid = int(pidfile.read_text())
            children = list(runtime.children)
            runtime.close()
            self.assertTrue(all(child.poll() is not None for _, child in children))
            with self.assertRaises(ProcessLookupError):
                os.kill(pid, 0)
        finally:
            runtime.close()

    def test_disabled_entrypoint_forwards_flags(self):
        tools = Path(self.temp.name)
        for name, body in {"id": "printf '1234\\n'", "dsh": "printf '%s\\n' \"$@\""}.items():
            tool = tools / name
            tool.write_text("#!/bin/sh\n" + body + "\n")
            tool.chmod(0o755)
        env = {**os.environ, "PATH": f"{tools}:{os.environ['PATH']}", "DSH_HOME": self.temp.name,
               "DSH_GRAPHICS_ENABLED": "false", "DSH_PUBLIC_HOST": "", "DSH_TRUSTED_HOSTS": "",
               "XDG_DATA_HOME": ""}
        result = subprocess.run(["sh", str(ROOT / "docker-entrypoint.sh"), "--port", "3081"],
                                env=env, capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.splitlines(), ["web", "--patch", "/opt/deepseek-harness/proxy.patch.yml",
                                                     "--port", "3081", "--no-open"])
        env["DSH_GRAPHICS_ENABLED"] = "typo"
        invalid = subprocess.run(["sh", str(ROOT / "docker-entrypoint.sh")], env=env, capture_output=True)
        self.assertEqual(invalid.returncode, 1)


if __name__ == "__main__":
    unittest.main()
