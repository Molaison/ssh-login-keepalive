"""Mock only system service managers and SSH, never a real cluster login."""

import os
import plistlib
import pty
import select
import shlex
import subprocess
import sys
import tarfile
import tempfile
import time
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

    def bootstrap_through_pipe(self, platform):
        self.stub("uname", f'printf "{platform}\\n"')
        archive = self.root / "github-source.tar.gz"
        with tarfile.open(archive, "w:gz") as source:
            for file in ("keepalivectl", "ssh-login-keepalive@.service"):
                source.add(PACKAGE / file, arcname="ssh-login-keepalive-main/" + file)
        self.env["TEST_ARCHIVE"] = str(archive)
        self.stub(
            "curl",
            'printf "curl %s\\n" "$*" >> "$TEST_LOG"\n'
            'previous=; output=\n'
            'for argument in "$@"; do\n'
            '  if [ "$previous" = -o ]; then output=$argument; fi\n'
            '  previous=$argument\n'
            'done\n'
            '[ -n "$output" ] || exit 2\n'
            'cp "$TEST_ARCHIVE" "$output"',
        )

        pid, master = pty.fork()
        if pid == 0:
            command = f"cat {shlex.quote(str(PACKAGE / 'install.sh'))} | sh"
            os.execvpe("sh", ["sh", "-c", command], self.env)

        transcript = bytearray()
        replied_to_user = False
        replied_to_host = False
        deadline = time.monotonic() + 20
        try:
            while time.monotonic() < deadline:
                if not select.select([master], [], [], 0.25)[0]:
                    continue
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break  # EIO when child closes its controlling terminal.
                if not chunk:
                    break
                transcript.extend(chunk)
                if b"SSH username:" in transcript and not replied_to_user:
                    os.write(master, b"alice\n")
                    replied_to_user = True
                if b"Target SSH hostname or SSH alias:" in transcript and not replied_to_host:
                    os.write(master, b"login.example.org\n")
                    replied_to_host = True
            else:
                self.fail("Bootstrap did not finish: " + transcript.decode(errors="replace"))
            _, status = os.waitpid(pid, 0)
            self.assertEqual(os.waitstatus_to_exitcode(status), 0, transcript.decode(errors="replace"))
        finally:
            os.close(master)

        output = transcript.decode(errors="replace")
        self.assertIn("Installation complete. Profile: alice-login-example-org", output)
        self.assertIn("curl -fsSL --retry 2", self.log.read_text())
        self.assertIn("ssh -n -T", self.log.read_text())

    def test_one_line_bootstrap_on_linux(self):
        self.bootstrap_through_pipe("Linux")
        conf = self.home / ".config/ssh-login-keepalive/alice-login-example-org.env"
        self.assertEqual(conf.read_text(), "TARGET=alice@login.example.org\n")
        self.assertTrue((self.home / ".local/share/ssh-login-keepalive/keepalivectl").exists())

    def test_one_line_bootstrap_on_macos(self):
        self.bootstrap_through_pipe("Darwin")
        plist = next((self.home / "Library/LaunchAgents").glob("*.plist"))
        with plist.open("rb") as file:
            self.assertEqual(plistlib.load(file)["ProgramArguments"][-2], "alice@login.example.org")


if __name__ == "__main__":
    unittest.main()
