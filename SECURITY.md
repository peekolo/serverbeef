# Security

serverbeef is a host configuration baseline, not a guarantee of server or application security.
Its security must hold with the entire script public. Keep private keys, passwords, application tokens,
provider credentials and local configuration files out of the repository and its Git history.

## Boundaries

- Run only reviewed code as root. Downloading from a moving branch trusts every future change to that branch;
  for repeatable deployments, review and pin a full commit SHA and retain the reviewed file's checksum.
- Protect the admin SSH key. Passwordless sudo and Docker group membership both provide root-equivalent
  access. Keep application deployment accounts separate from the admin account.
- A custom SSH port is discoverable. Authentication, patching and network policy provide protection.
- Docker-published ports can bypass UFW. Review host bindings, container networks, IPv4 and IPv6, and the
  provider firewall. A green UFW status alone is insufficient.
- Cloudflare protects requests routed through it. Separately restrict origin access and verify that internal
  databases and application services cannot be reached directly.
- Application authorization, dependencies, secrets, database permissions, backups and recovery require their
  own review. This script does not validate them.
- Provider images often ship a second account with a password and passwordless sudo (`linuxuser`, `ubuntu`).
  The script leaves existing accounts alone; verify mode lists them so the owner can lock or remove them.
- Existing root-controlled SSH includes, sudo rules and firewall policies can conflict with this baseline.
  Verification samples SSH connection contexts; it cannot prove every possible `Match` rule is safe.

Do not paste credentials or private deployment details into public issues. If GitHub private vulnerability
reporting is enabled for this repository, use its **Security → Report a vulnerability** entry. Otherwise,
request a private contact channel without posting exploit details or secrets.

## Migration notes

This revision treats `--config` files as literal settings, not executable shell scripts. Convert configs using
shell expansions or commands before upgrading. Restrictions on root SSH keys are no longer removed when
copying keys; supply a personal unrestricted admin key if the provider's root key has a forced command.
Review keys copied by older versions and revoke any unintended access.

Key-file writes run as the account owner. A root-owned `authorized_keys` file that the admin cannot update
causes setup to stop rather than silently changing ownership. Review and repair ownership deliberately while
retaining a working administrator session.

Passwordless admins use a direct sudoers rule and the `ssh-users` group; setup removes their membership in
the `sudo` group to avoid its conflicting password-required rule during `sudo -v`. This does not remove their
sudo privileges. Password-required admins use the normal `sudo` group. Setup validates passwordless sudo
as the admin before changing SSH; unrelated sudoers rules may still need manual review.

Generated passwords are delivered directly to the terminal before account updates. Without a terminal,
they are saved to `/root/serverbeef-<user>-password.txt` with mode `600`. Retrieve the credential privately
and remove the file once stored securely. No password is included in saved settings or setup logs.
Do not enable shell tracing around secret handling.

## Validation

Run `bash -n serverbeef.sh`, `shellcheck serverbeef.sh`, and
`python3 -m unittest discover -s tests -v`. The regression suite extracts individual helpers and never runs
host setup. It covers literal config loading, key restrictions and validation, password line-break rejection,
port validation, random port range, unsafe key-file links, key append idempotence, effective SSH policy checks
and rollback.

Before release, run the complete script twice on a disposable Ubuntu 26.04 VM, compare managed configuration,
test a new SSH connection and sudo, and run `--verify`. Include IPv6, socket-activated SSH, existing SSH overrides,
and upgrade cases. Never substitute a production server for this test.

References: [OpenSSH configuration](https://man.openbsd.org/sshd_config),
[Docker firewall behavior](https://docs.docker.com/engine/network/packet-filtering-firewalls/).
