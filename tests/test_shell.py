"""Mock only system service managers and SSH, never a real cluster login."""

import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PACKAGE = Path(__file__).resolve().parents[1]


class ShellInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ssh-keepalive-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "a & b"
        self.home.mkdir()
        self.bin_dir = self.root / "bin"
        self.bin_dir.mkdir()
        self.log = self.root / "calls.log"
        self.env = dict(os.environ)
        self.env.update(
            HOME=str(self.home),
            TEST_LOG=str(self.log),
            PATH=f"{self.bin_dir}{os.pathsep}{os.environ['PATH']}",
        )
        self.stub(
            "ssh",
            'printf "ssh %s\\n" "$*" >> "$TEST_LOG"\n'
            'exit "${TEST_SSH_FAIL:-0}"',
        )
        self.stub(
            "systemctl",
            'printf "systemctl %s\\n" "$*" >> "$TEST_LOG"',
        )
        self.stub("loginctl", 'printf "no\\n"')
        self.stub(
            "launchctl",
            'printf "launchctl %s\\n" "$*" >> "$TEST_LOG"\n'
            'if [ "$1" = print ]; then\n'
            '  if [ "${TEST_NO_GUI:-0}" = 1 ]; then exit 1; fi\n'
            '  case "$2" in gui/*/*) test "${TEST_LAUNCH_LOADED:-0}" = 1;; esac\n'
            'fi\n'
            'exit 0',
        )
        self.stub("plutil", 'printf "plutil %s\\n" "$*" >> "$TEST_LOG"')

    def stub(self, name, body):
        path = self.bin_dir / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def run_cli(self, *args, success=True):
        result = subprocess.run(
            ["bash", str(PACKAGE / "keepalivectl"), *args],
            env=self.env,
            capture_output=True,
            text=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def test_linux_install_update_guard_and_remove(self):
        self.stub("uname", 'printf "Linux\\n"')
        result = self.run_cli("install", "cluster", "alice@cluster.example.org")
        self.assertIn("service stops on logout", result.stderr)
        conf = self.home / ".config/ssh-login-keepalive/cluster.env"
        self.assertEqual(conf.read_text(), "TARGET=alice@cluster.example.org\n")
        unit = self.home / ".config/systemd/user/ssh-login-keepalive@.service"
        self.assertIn("ExecStart=" + str(self.bin_dir / "ssh"), unit.read_text())
        self.assertIn("Restart=always", unit.read_text())
        self.assertNotIn("@SSH_PATH@", unit.read_text())
        self.run_cli("status", "cluster")
        self.env["TEST_SSH_FAIL"] = "1"
        self.run_cli("install", "cluster", "alice@other.example.org", success=False)
        self.assertEqual(conf.read_text(), "TARGET=alice@cluster.example.org\n")
        self.env.pop("TEST_SSH_FAIL")
        self.run_cli("remove", "cluster")
        self.assertFalse(conf.exists())
        recorded = self.log.read_text()
        self.assertIn("systemctl --user enable ssh-login-keepalive@cluster.service", recorded)
        self.assertIn("systemctl --user disable --now ssh-login-keepalive@cluster.service", recorded)

    def test_macos_plist_and_lifecycle(self):
        self.stub("uname", 'printf "Darwin\\n"')
        self.run_cli("install", "lab", "alice@login.example.org")
        plist = next((self.home / "Library/LaunchAgents").glob("*.plist"))
        with plist.open("rb") as file:
            content = plistlib.load(file)
        if sys.platform == "darwin":
            subprocess.run(["/usr/bin/plutil", "-lint", str(plist)], check=True, capture_output=True)
        self.assertEqual(content["ProgramArguments"][0], str(self.bin_dir / "ssh"))
        self.assertEqual(content["ProgramArguments"][-2:], ["alice@login.example.org", "exec sleep infinity"])
        self.assertTrue(content["KeepAlive"])
        self.assertTrue(content["RunAtLoad"])
        self.assertIn("a & b", content["StandardErrorPath"])
        self.assertIn("&amp;", plist.read_text())
        self.env["TEST_LAUNCH_LOADED"] = "1"
        self.run_cli("install", "lab", "alice@other.example.org")
        with plist.open("rb") as file:
            self.assertEqual(plistlib.load(file)["ProgramArguments"][-2], "alice@other.example.org")
        self.run_cli("status", "lab")
        self.run_cli("remove", "lab")
        self.assertFalse(plist.exists())
        self.assertIn("launchctl bootout gui/", self.log.read_text())

    def test_macos_requires_gui_domain(self):
        self.stub("uname", 'printf "Darwin\\n"')
        self.env["TEST_NO_GUI"] = "1"
        result = self.run_cli("install", "cluster", "alice@cluster.example.org", success=False)
        self.assertIn("logged-in macOS desktop", result.stderr)
        self.assertFalse((self.home / "Library/LaunchAgents").exists())

    def test_bad_name_is_rejected(self):
        self.stub("uname", 'printf "Linux\\n"')
        self.run_cli("install", "../escape", "alice@cluster.example.org", success=False)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
