"""Regression tests run extracted helpers, never the root setup program.

Run: python3 -m unittest discover -s tests -v
"""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "serverbeef.sh").read_text()


def function(name):
    lines = SOURCE.splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(name + "()"))
    if lines[start].rstrip().endswith("}"):
        return lines[start] + "\n"
    end = next(i for i in range(start + 1, len(lines)) if lines[i] == "}")
    return "\n".join(lines[start:end + 1]) + "\n"


HELPERS = "".join(function(name) for name in (
    "load_config", "valid_port", "valid_ports", "valid_sshkey",
    "valid_password", "extract_key", "count_keys", "ssh_policy_ok",
    "restore_sshd_dropin", "add_key", "deliver_generated_password", "automatic_updates_enabled",
    "random_port", "rootless_docker_unit", "docker_group_members", "next_subid_range",
))
STATE_KEYS = re.search(r'^STATE_KEYS="([^"]+)"', SOURCE, re.M)[1]


class SecurityTests(unittest.TestCase):
    def test_update_verification_reads_complete_effective_configuration(self):
        for enabled in (True, False):
            with self.subTest(enabled=enabled):
                settings = self.directory / "apt-settings"
                settings.write_text('APT::Periodic::Update-Package-Lists "1";\n'
                                    'APT::Periodic::Unattended-Upgrade "1";\n' +
                                    'APT::Unrelated "padding";\n' * 10000 +
                                    ('' if enabled else 'APT::Periodic::Enable "0";\n'))
                result = self.shell('systemctl() { return 0; }; '
                                    'apt-config() { cat "$SETTINGS"; }; '
                                    'automatic_updates_enabled', env={"SETTINGS": str(settings)})
                self.assertEqual(result.returncode, 0 if enabled else 1, result.stderr)

    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="serverbeef-tests-")
        cls.directory = Path(cls.temp.name)
        cls.keyfile = cls.directory / "admin"
        subprocess.run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(cls.keyfile)],
            check=True, capture_output=True,
        )
        cls.key = cls.keyfile.with_suffix(".pub").read_text().strip()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def shell(self, program, *args, env=None):
        variables = os.environ.copy()
        variables.update(STATE_KEYS=STATE_KEYS)
        if env:
            variables.update(env)
        return subprocess.run(
            ["bash", "-c", "set -euo pipefail\n" + HELPERS + program, "test", *args],
            env=variables, capture_output=True, text=True,
        )

    def test_config_never_executes_substitution_or_backticks(self):
        marker = self.directory / "must-not-exist"
        config = self.directory / "config"
        value = f'$(touch {marker}) `touch {marker}` $HOME'
        config.write_text(f'ADMIN_PASSWORD="{value}"\n')
        result = self.shell('load_config "$1"; printf "%s" "$ADMIN_PASSWORD"', str(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, value)
        self.assertFalse(marker.exists())

    def test_config_rejects_commands_and_internal_variables(self):
        config = self.directory / "bad-config"
        for line in ("touch /tmp/serverbeef-not-permitted", "PATH=/tmp",
                     "BASH_ENV=/tmp/file", "STATE_KEYS=PATH", "LOG_FILE=/tmp/log",
                     "MODE=setup", "ADMIN_USER=alice; false", "source /tmp/file"):
            with self.subTest(line=line):
                config.write_text(line + "\n")
                result = self.shell('load_config "$1"', str(config))
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(line, result.stderr)

    def test_config_literal_quotes_empty_and_final_line(self):
        config = self.directory / "literal-config"
        config.write_text('# comment\n\nADMIN_USER=alice\nFIREWALL_TCP_PORTS="80 443"\n'
                          "FIREWALL_UDP_PORTS=''\nTIMEZONE=UTC")
        result = self.shell(
            'load_config "$1"; printf "%s|%s|%s|%s" "$ADMIN_USER" '
            '"$FIREWALL_TCP_PORTS" "$FIREWALL_UDP_PORTS" "$TIMEZONE"', str(config))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "alice|80 443||UTC")

    def test_config_rejects_unbalanced_quotes(self):
        config = self.directory / "quote-config"
        for value in ('"', "'", '"abc', "abc'"):
            with self.subTest(value=value):
                config.write_text(f"ADMIN_USER={value}\n")
                result = self.shell('load_config "$1"', str(config))
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("substring", result.stderr)

    def test_random_port_stays_in_range_and_avoids_common_ports(self):
        common = ("2222", "3000", "5432", "8080", "8443", "9000")
        for _ in range(50):
            result = self.shell('ss() { :; }; random_port')
            self.assertEqual(result.returncode, 0, result.stderr)
            port = int(result.stdout)
            self.assertTrue(1025 <= port <= 9999, port)
            self.assertNotIn(str(port), common)

    def test_rootless_docker_unit_keeps_source_addresses_and_runs_given_script(self):
        result = self.shell('rootless_docker_unit /usr/share/docker.io/contrib/dockerd-rootless.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        unit = result.stdout
        self.assertIn("Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_NET=pasta\n", unit)
        self.assertIn("Environment=DOCKERD_ROOTLESS_ROOTLESSKIT_PORT_DRIVER=implicit\n", unit)
        self.assertIn("ExecStart=/usr/share/docker.io/contrib/dockerd-rootless.sh\n", unit)
        self.assertIn("ExecReload=/bin/kill -s HUP $MAINPID\n", unit)
        self.assertIn("WantedBy=default.target\n", unit)

    def test_docker_group_members_ignores_root_and_empty_group(self):
        for line, expected in (("docker:x:107:", ""), ("docker:x:107:root", ""),
                               ("docker:x:107:alice,root,bob", "alice\nbob\n"), ("", "")):
            with self.subTest(line=line):
                result = self.shell(f'getent() {{ printf "%s\\n" "{line}"; }}; docker_group_members')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_next_subid_range_starts_above_existing_ranges(self):
        subuid = self.directory / "subuid"
        for content, expected in (("", "100000-165535"),
                                  ("alice:100000:65536\n", "165536-231071"),
                                  ("alice:100000:65536\nbob:231072:65536\n", "296608-362143"),
                                  ("broken line\n", "100000-165535")):
            with self.subTest(content=content):
                subuid.write_text(content)
                result = self.shell('next_subid_range "$1"', str(subuid))
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), expected)
        result = self.shell('next_subid_range "$1"', str(self.directory / "missing"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "100000-165535")

    def test_cli_does_not_trace_config_password(self):
        config = self.directory / "trace-config"
        sentinel = "serverbeef-test-only-secret"
        config.write_text(f'ADMIN_PASSWORD="{sentinel}"\n')
        result = subprocess.run(
            ["bash", "-x", str(Path(__file__).resolve().parents[1] / "serverbeef.sh"),
             "--config", str(config), "--help"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(sentinel, result.stdout + result.stderr)

    def test_cli_cannot_execute_config_before_help(self):
        marker = self.directory / "cli-must-not-exist"
        config = self.directory / "executable-config"
        config.write_text(f'touch {marker}\n')
        result = subprocess.run(
            ["bash", str(Path(__file__).resolve().parents[1] / "serverbeef.sh"),
             "--config", str(config), "--help"],
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(marker.exists())

    def test_port_boundaries_and_invalid_arithmetic(self):
        for port in ("1", "22", "65535"):
            self.assertEqual(self.shell('valid_port "$1"', port).returncode, 0)
        for port in ("0", "65536", "999999999999999999999", "-1", "08",
                     "22+1", "a[$(touch /tmp/no)]", "22\nPermitRootLogin yes"):
            with self.subTest(port=port):
                self.assertNotEqual(self.shell('valid_port "$1"', port).returncode, 0)

    def test_port_ranges(self):
        for ports in ("", "80 443", "1024:2048 443"):
            self.assertEqual(self.shell('valid_ports "$1"', ports).returncode, 0)
        for ports in ("0:80", "443:80", "80:80", "1:65536", "080:443", "1:2:3", "*", "?"):
            with self.subTest(ports=ports):
                self.assertNotEqual(self.shell('valid_ports "$1"', ports).returncode, 0)

    def test_password_rejects_chpasswd_record_injection(self):
        self.assertEqual(self.shell('valid_password "$1"', "ordinary:password").returncode, 0)
        for password in ("password\nroot:replacement", "password\rroot:replacement"):
            self.assertNotEqual(self.shell('valid_password "$1"', password).returncode, 0)

    def test_unattended_credential_is_private_and_does_not_follow_symlink(self):
        target = self.directory / "credential-target"
        target.write_text("unchanged")
        credential = self.directory / "serverbeef-test-password.txt"
        credential.symlink_to(target)
        sentinel = "fake-test-credential"
        result = subprocess.run(
            ["bash", "-c", "set -euo pipefail\n" + HELPERS +
             'ADMIN_USER=test; MARK=serverbeef; GENERATED_PASSWORD="$2"; '
             'deliver_generated_password "$1"', "test", str(self.directory), sentinel],
            capture_output=True, text=True, start_new_session=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(sentinel, result.stdout + result.stderr)
        self.assertFalse(credential.is_symlink())
        self.assertEqual(credential.stat().st_mode & 0o777, 0o600)
        self.assertEqual(credential.read_text(), sentinel + "\n")
        self.assertEqual(target.read_text(), "unchanged")

    def test_root_key_restrictions_are_never_removed(self):
        for prefix in ('command="/bin/false" ', 'restrict ', 'from="192.0.2.1" ',
                       '# ', 'cert-authority '):
            result = self.shell('extract_key "$1"', prefix + self.key)
            self.assertEqual(result.stdout, "")
        result = self.shell('extract_key "$1"', self.key)
        self.assertEqual(result.stdout.strip(), self.key)

    def test_corrupt_and_multiline_keys_rejected(self):
        for key in ("ssh-ed25519 AAAAnotAKey", self.key + "\n" + self.key,
                    self.key + "\r"):
            self.assertNotEqual(self.shell('valid_sshkey "$1"', key).returncode, 0)

    def test_count_requires_valid_unrestricted_key_and_handles_no_final_newline(self):
        keys = self.directory / "authorized_keys"
        keys.write_text('ssh-ed25519 AAAAnotAKey\nrestrict ' + self.key + "\n" + self.key)
        result = self.shell('count_keys "$1"', str(keys))
        self.assertEqual(result.stdout, "1\n")
        self.assertEqual(self.shell('count_keys "$1"', str(keys) + "-missing").stdout, "0\n")

    def test_key_append_is_idempotent_and_separates_lines(self):
        keys = self.directory / "append_keys"
        keys.write_text("# existing final line")
        # The stub only removes runuser's identity arguments. The real child
        # shell still performs file operations in this temporary directory.
        result = self.shell(
            'runuser() { shift 3; "$@"; }\n'
            'ADMIN_USER=test; AUTH_KEYS="$1"; add_key "$2"; add_key "$2"',
            str(keys), self.key)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(keys.read_text(), "# existing final line\n" + self.key + "\n")

    def test_key_append_refuses_symlink_and_hardlink(self):
        target = self.directory / "protected-target"
        target.write_text("keep\n")
        symbolic = self.directory / "symbolic"
        symbolic.symlink_to(target)
        hard = self.directory / "hard"
        os.link(target, hard)
        for path in (symbolic, hard):
            result = self.shell(
                'runuser() { shift 3; "$@"; }\n'
                'ADMIN_USER=test; AUTH_KEYS="$1"; add_key "$2"', str(path), self.key)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(target.read_text(), "keep\n")

    def test_ssh_failure_preserves_first_install_state(self):
        active = self.directory / "first-install.conf"
        active.write_text("bad candidate\n")
        result = self.shell(
            'SSHD_DROPIN="$1"; SSHD_BACKUP=""; restore_sshd_dropin', str(active))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(active.exists())
        self.assertEqual(Path(str(active) + ".broken").read_text(), "bad candidate\n")

    def policy(self, config, override=""):
        return self.shell(
            'ADMIN_USER=alice; SSH_PORT=4821; HAVE_KEYS=yes; unset SSH_CONNECTION\n'
            'sshd() { if [[ "$*" == *"user=alice"* && -n "$OVERRIDE" ]]; then '
            'printf "%s\\n" "$OVERRIDE"; else printf "%s\\n" "$CONFIG"; fi; }\n'
            'ssh_policy_ok', env={"CONFIG": config, "OVERRIDE": override})

    def test_effective_ssh_policy_including_match_contexts(self):
        good = ("port 4821\npubkeyauthentication yes\nkbdinteractiveauthentication no\n"
                "passwordauthentication no\npermitrootlogin no\n"
                "authenticationmethods publickey")
        self.assertEqual(self.policy(good).returncode, 0)
        for before, after in (("passwordauthentication no", "passwordauthentication yes"),
                              ("permitrootlogin no", "permitrootlogin yes"),
                              ("authenticationmethods publickey", "authenticationmethods any"),
                              ("kbdinteractiveauthentication no", "kbdinteractiveauthentication yes")):
            with self.subTest(setting=before):
                self.assertNotEqual(self.policy(good.replace(before, after)).returncode, 0)
                self.assertNotEqual(self.policy(good, good.replace(before, after)).returncode, 0)
        self.assertNotEqual(self.policy(good + "\nport 22").returncode, 0)
        self.assertNotEqual(self.policy(good.replace("4821", "22")).returncode, 0)

    def test_ssh_rollback_preserves_previous_policy(self):
        active = self.directory / "ssh.conf"
        backup = self.directory / "previous"
        active.write_text("bad candidate\n")
        backup.write_text("previous working settings\n")
        result = self.shell(
            'SSHD_DROPIN="$1"; SSHD_BACKUP="$2"; restore_sshd_dropin',
            str(active), str(backup))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(active.read_text(), "previous working settings\n")
        self.assertEqual(Path(str(active) + ".broken").read_text(), "bad candidate\n")


if __name__ == "__main__":
    unittest.main()
