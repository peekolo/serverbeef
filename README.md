# serverbeef

One bash script that turns a fresh Ubuntu 26.04 VPS into a hardened server for web apps. Run it as root on a new
box, answer a few questions (or pass flags), and it sets up a sudo admin with key-only SSH, a firewall, fail2ban,
automatic security updates, kernel and network tuning, swap, and optionally Docker.

Every step can be re-run safely. A second run offers to check the server instead, and the check can also clean up
old firewall rules and run a Lynis audit.

## Quick start

On a new Ubuntu 26.04 x64 server, as root, with your SSH key already on root (most providers do this when you create
the server):

```bash
scp serverbeef.sh root@<ip>:
ssh -t root@<ip> 'bash serverbeef.sh'
```

The wizard asks for each setting and shows its default. When it finishes, **keep that session open** and test the new
login from a second terminal:

```bash
ssh -p 2222 <admin>@<ip>
sudo -v
sudo serverbeef --verify
```

Only close the root session once that works. If something is wrong, you can still fix it from the session that is
open.

Unattended, with flags instead of the wizard:

```bash
bash serverbeef.sh --yes --user alice --docker --udp-ports none
```

## What it does

| Step | Result |
|---|---|
| 1. Packages | Full upgrade, then common tools (curl, jq, git, htop, tmux, vim, dnsutils...), ufw, fail2ban, unattended-upgrades, chrony, AppArmor, Lynis. `needrestart` restarts services without asking |
| 2. Hostname, time | Optional hostname and timezone; time sync with chrony |
| 3. Admin user | Creates the sudo user, installs your public key(s) and copies root's authorized keys. Passwordless sudo when a key is installed, otherwise a password (generated if you give none, shown once and never written to the log) |
| 4. SSH | Custom port (2222), key-only login, no root login, only the `sudo` and `ssh-users` groups may log in, agent/X11 forwarding off, `ssh -L` tunnels allowed by default. The config is tested with `sshd -t` before it is used |
| 5. Firewall | UFW denies incoming by default; SSH (rate limited), 80/tcp, 443/tcp and 443/udp are open. `--tcp-ports` and `--udp-ports` change the list |
| 6. Fail2ban | SSH jail in aggressive mode, bans that get longer for repeat offenders, and a recidive jail (one week) |
| 7. Updates | Unattended security upgrades, with an automatic reboot at 04:00 when one is needed (can be turned off) |
| 8. Kernel, network | BBR and fq, larger queues and buffers, SYN cookies, no redirects or source routing, restricted kernel pointers, dmesg, ptrace and unprivileged BPF |
| 9. Swap, limits, logs | A swap file sized to RAM (1 to 4 GB) if there is none, higher open-file limits, journald capped at 1 GB and one month |
| 10. Misc | Core dumps off, `su` limited to the sudo group, home folders private, unused protocols and filesystems blocked, Ctrl-Alt-Del from the provider console ignored |
| 11. Docker (optional) | Docker and Compose from Ubuntu's packages, log rotation, `live-restore`, admin in the `docker` group |

Every file it writes has `serverbeef` in its name (`/etc/ssh/sshd_config.d/00-serverbeef.conf`,
`/etc/sysctl.d/90-serverbeef.conf` and so on), so you can see what came from the script. The settings you chose are
saved in `/etc/serverbeef/state.conf` (never passwords or keys), and the script copies itself to
`/usr/local/sbin/serverbeef`.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `-u, --user NAME` | `deploy` | Admin (sudo) user to create or update |
| `-k, --ssh-key "KEY"` | | Public key for the admin; repeat for several |
| `--no-copy-root-keys` | | Don't copy root's authorized keys to the admin |
| `--sudo-nopasswd` / `--sudo-password` | auto | Passwordless sudo is the default when a key is installed |
| `-p, --ssh-port PORT` | `2222` | SSH port |
| `--forwarding no\|local\|yes` | `local` | SSH TCP forwarding |
| `--tcp-ports "P ..."` | `"80 443"` | Public TCP ports besides SSH |
| `--udp-ports "P ..."` | `"443"` | Public UDP ports (HTTP/3); `none` for none |
| `--hostname NAME`, `--timezone TZ` | unchanged | |
| `--swap auto\|none\|2G` | `auto` | Swap file size |
| `--auto-reboot` / `--no-auto-reboot`, `--reboot-time HH:MM` | on, `04:00` | Reboots after updates |
| `--docker` / `--no-docker` | off | Install Docker and Compose |
| `--verify` | | Check a server this script already set up |
| `--setup` | | On a re-run, skip the menu and run setup again |
| `-c, --config FILE` | | Load settings from a file of `VAR=value` lines |
| `-y, --yes` | | No wizard; run with the values given |

Every option can also be set as an environment variable (`SSH_PORT=2200`, `INSTALL_DOCKER=yes`, `ADMIN_PASSWORD=...`).
The full list is in `bash serverbeef.sh --help`.

## Verify mode

`sudo serverbeef --verify` (or the menu on a re-run) changes nothing unless you agree. It checks that SSH listens
on the right port and is key-only, the admin exists with sudo and keys, UFW is active with the ports you chose,
fail2ban jails are running, updates are on, BBR, swap, AppArmor and the clock are fine, and that no Docker container
publishes a port past the firewall. It offers to delete firewall rules that are not in your settings (such as the
old port 22), then runs a quick Lynis audit and prints the score and warnings.

## Things to know

- Docker-published ports bypass UFW. Docker writes its own iptables rules, so `-p 5432:5432` is open to the
  internet whatever UFW says. Bind internal services to localhost (`-p 127.0.0.1:5432:5432`), put a firewall at your
  provider in front of the server, or both. The script warns about this and the verify mode lists exposed ports.
- Port 22 stays open in UFW until you remove it. If your provider added a rule for port 22, the script prints the
  exact delete command, and verify mode offers to remove it once you are logged in on the new port.
- Without an SSH key, password login stays on. So that you can't be locked out, key-only login is turned on only
  when the admin has at least one key. Add a key and run the script again.
- With a key, sudo needs no password by default, so whoever holds that key is root. Use `--sudo-password` if you
  want a second factor.
- At the end the script asks `ifconfig.me` for the server's public IP, only to print the right `ssh` command.
- It targets Ubuntu 26.04 on x86_64. It warns on other versions and architectures and refuses non-Ubuntu systems.
- It also works with `curl ... | sudo bash`, because the wizard reads from `/dev/tty`. Read the script before you
  pipe anything from the internet into a root shell.

## For AI agents

[CLAUDE.md](CLAUDE.md) (also `AGENTS.md`) explains how to run the script on someone's behalf and how to change it
without breaking re-runs or locking anyone out.

## License

MIT, see [LICENSE](LICENSE).
