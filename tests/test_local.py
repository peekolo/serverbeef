"""Tests for the helpers of serverbeef-local.sh (the workstation script). Never touches ~/.ssh.

Run: python3 -m unittest discover -s tests -v
"""
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "serverbeef-local.sh").read_text()


def function(name):
    lines = SOURCE.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(name + "()"))
    if lines[start].rstrip().endswith("}"):
        return lines[start] + "\n"
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")
    return "\n".join(lines[start:end + 1]) + "\n"


HELPERS = "".join(function(name) for name in (
    "valid_ip", "valid_name", "valid_admin", "valid_port", "expand_tilde",
    "config_blocks_for", "remove_blocks_for", "key_used_elsewhere",
))

CONFIG = """# global
ServerAliveInterval 30

Host other
  HostName 203.0.113.9
  User me
  IdentityFile ~/.ssh/other_key

Host box1
  HostName 203.0.113.10
  Port 4821
  User yang
  IdentityFile ~/.ssh/box1_admin
  IdentitiesOnly yes

Host box1_deploy
  HostName 203.0.113.10
  Port 4821
  User deploy
  IdentityFile ~/.ssh/box1_deploy

Host shared
  HostName 203.0.113.11
  IdentityFile ~/.ssh/box1_admin

Match host nothing
  User nobody
"""


class LocalScriptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.directory = Path(self.tmp.name)
        self.config = self.directory / "config"
        self.config.write_text(CONFIG)

    def tearDown(self):
        self.tmp.cleanup()

    def shell(self, program, *args):
        return subprocess.run(["bash", "-c", "set -euo pipefail\n" + HELPERS + program, "test", *args],
                              capture_output=True, text=True, env={"HOME": str(self.directory), "PATH": "/usr/bin:/bin"})

    def test_blocks_for_ip_lists_every_matching_host_with_empty_fields_kept(self):
        result = self.shell('config_blocks_for "$1" 203.0.113.10', str(self.config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ["box1|yang|4821|~/.ssh/box1_admin", "box1_deploy|deploy|4821|~/.ssh/box1_deploy"])
        result = self.shell('config_blocks_for "$1" 203.0.113.11', str(self.config))
        self.assertEqual(result.stdout.splitlines(), ["shared|||~/.ssh/box1_admin"])
        result = self.shell('config_blocks_for "$1" 198.51.100.1; config_blocks_for "$1/missing" 203.0.113.10', str(self.config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")

    def test_remove_blocks_keeps_everything_else_including_global_options(self):
        result = self.shell('remove_blocks_for "$1" 203.0.113.10', str(self.config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("box1", result.stdout.replace("box1_admin", ""))
        self.assertIn("ServerAliveInterval 30", result.stdout)
        self.assertIn("Host other\n  HostName 203.0.113.9\n  User me\n", result.stdout)
        self.assertIn("Host shared\n  HostName 203.0.113.11\n", result.stdout)
        self.assertIn("Match host nothing\n  User nobody\n", result.stdout)
        self.assertNotIn("\n\n\n", result.stdout)

    def test_key_used_elsewhere_sees_other_hosts_only(self):
        result = self.shell('key_used_elsewhere "$1" 203.0.113.10 ~/.ssh/box1_admin && echo used', str(self.config))
        self.assertEqual(result.stdout.strip(), "used", "box1_admin is also the key of 'shared'")
        result = self.shell('key_used_elsewhere "$1" 203.0.113.10 ~/.ssh/box1_deploy || echo free', str(self.config))
        self.assertEqual(result.stdout.strip(), "free")
        result = self.shell('key_used_elsewhere "$1" 203.0.113.10 "$HOME/.ssh/box1_admin" && echo used', str(self.config))
        self.assertEqual(result.stdout.strip(), "used", "a tilde path and an expanded path are the same key")

    def test_validators(self):
        cases = {
            "valid_ip": {"203.0.113.10": True, "box.example.com": True, "not an ip": False, "": False},
            "valid_name": {"box1": True, "my-server": True, "box_deploy": False, "Box": False, "": False},
            "valid_admin": {"yang": True, "root": False, "deploy": False, "Yang": False, "": False},
            "valid_port": {"4821": True, "22": False, "65535": True, "70000": False, "abc": False},
        }
        for fn, values in cases.items():
            for value, expected in values.items():
                with self.subTest(fn=fn, value=value):
                    result = self.shell(f'{fn} "$1" && echo yes || echo no', value)
                    self.assertEqual(result.stdout.strip(), "yes" if expected else "no", result.stderr)


if __name__ == "__main__":
    unittest.main()
