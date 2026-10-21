# serverbeef

You built an app with AI and rented a server to put it online. A new server is easy to break into: anyone on the
internet can try to guess a password if password login is enabled, and firewall and update policies vary by
provider. serverbeef applies a baseline of host protections. You copy one command and answer a few questions,
then test the new login and review the verification results. It does not audit your applications or guarantee
that a server cannot be compromised. See [SECURITY.md](SECURITY.md) for the security boundaries.

It works on a fresh **Ubuntu 26.04** server from any provider (DigitalOcean, Hetzner, Vultr, Linode and so on). It
takes about ten minutes.

## How to use it

You need the server's IP address (it's on your provider's dashboard) and a terminal on your own computer: the
Terminal app on a Mac, or PowerShell on Windows.

### 1. Make a login key on your computer

A key is a pair of files that lets you log in using a private credential stored on your computer. Skip this step if you already
have one.

In the terminal on your computer, run:

```bash
ssh-keygen -t ed25519
```

Accept the default file location unless you already have a key there. Protect the private key with a passphrase.
Then print your public key:

```bash
cat ~/.ssh/id_ed25519.pub
```

You'll see one long line that starts with `ssh-ed25519`. Copy the whole line; you'll paste it in step 3. (If
`ssh-keygen` says the file already exists, you have a key already. Type `n`, then run the `cat` command.)

### 2. Log in to your server

```bash
ssh root@YOUR_SERVER_IP
```

Put your server's IP address in place of `YOUR_SERVER_IP`. The first time, it asks whether you want to continue
connecting: type `yes`. If it asks for a password, use the root password from your provider.

### 3. Run serverbeef

Copy this line into the server window and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/peekolo/serverbeef/HEAD/serverbeef.sh -o serverbeef.sh && bash serverbeef.sh
```

It asks a few questions. Pressing Enter accepts the suggested answer shown in `[brackets]`, and that is fine for most
of them. Answer these ones yourself:

- For the admin username, type a short name of your own, such as your first name in lowercase. You'll log in with
  this account from now on, because logging in as root gets turned off.
- When it asks for a public key, paste the line you copied in step 1. Only copy keys from root if you recognize
  them as your personal admin keys. Restricted root keys are skipped; their restrictions are never stripped.
- If your app runs in Docker, answer yes to the Docker question.

Before it changes anything, it shows a summary and asks you to confirm. Find the SSH port there (a number
like `4821`) and write it down: from now on you log in on that port. At the end it prints the exact login command.
If a password is generated, save it in a password manager. It is delivered privately before changing the account,
so a later setup failure cannot lose it. Without a terminal it is saved in a root-only file; the script prints
that file's path. Delete the file after saving the password securely.

### 4. Test the new login before you close anything

**Leave the server window open.** Open a second terminal window on your computer and run the command from the end of
the setup. It looks like this:

```bash
ssh -p 4821 yourname@YOUR_SERVER_IP
sudo -v
```

If you get in and `sudo -v` finishes without an error, you're done. Close both windows whenever you like.

If it doesn't connect, keep the first window open, since it is still logged in and can fix things. The usual cause
is a firewall on your provider's dashboard (often called "Firewall" or "Security group") that blocks the new port.
Add a rule there that allows TCP on your SSH port, then try again.

From now on, log in with `ssh -p <port> <yourname>@<ip>`. To check the server later, run `sudo serverbeef --verify`
on it.

### 5. Put your app online

serverbeef only secures the server. To get your app running on it at your own domain, with HTTPS and Cloudflare
protection, use its companion project
[caddy-behind-cloudflare](https://github.com/peekolo/caddy-behind-cloudflare). It is a step-by-step playbook that
your AI assistant follows to deploy Docker apps onto the server, and you can run several apps on the same server.
Its README starts by cloning serverbeef, so you can use the two together from the beginning.

### Using an AI coding agent?

You can ask Claude Code or a similar agent to run serverbeef on your server for you. [CLAUDE.md](CLAUDE.md) tells
the agent how to do it without locking you out.

## Other ways to run it

The script supports re-runs. An interactive second run offers to check the server instead; unattended runs need
an explicit `--verify` to avoid running setup again. Review changes on a disposable server before updating an
existing deployment. Verification can also clean up old firewall rules and run a Lynis audit.

If you'd rather not download from the server, copy the script over yourself:

```bash
scp serverbeef.sh root@<ip>:
ssh -t root@<ip> 'bash serverbeef.sh'
```

Unattended, with flags instead of the questions:

```bash
bash serverbeef.sh --yes --user alice --ssh-port 4821 --ssh-key "ssh-ed25519 AAAA..." --docker --udp-ports none
```

It also works with `curl ... | sudo bash`, because the questions are read from `/dev/tty`. Read the script before you
pipe anything from the internet into a root shell.

## What it does

| Step | Result |
|---|---|
| 1. Packages | Full upgrade, then common tools (curl, jq, git, htop, tmux, vim, dnsutils...), ufw, fail2ban, unattended-upgrades, chrony, AppArmor, Lynis. `needrestart` restarts services without asking |
| 2. Hostname, time | Optional hostname and timezone; time sync with chrony |
| 3. Admin user | Creates the sudo user, installs your public key(s) and optionally copies unrestricted, validated root keys. Passwordless sudo when a key is installed, otherwise a password (generated if needed, delivered privately to the terminal or a root-only file and never written to the log) |
| 4. SSH | A port of its own for each server (random unless you choose one), key-only login, no root login, only the `sudo` and `ssh-users` groups may log in, agent/X11 forwarding off, `ssh -L` tunnels allowed by default. The config is tested with `sshd -t` before it is used |
| 5. Firewall | UFW denies incoming by default; SSH (rate limited), 80/tcp, 443/tcp and 443/udp are open. `--tcp-ports` and `--udp-ports` change the list |
| 6. Fail2ban | SSH jail in aggressive mode, bans that get longer for repeat offenders, and a recidive jail (one week) |
| 7. Updates | Unattended security upgrades, with an automatic reboot at 04:00 when one is needed (can be turned off) |
| 8. Kernel, network | BBR and fq, larger queues and buffers, SYN cookies, no redirects or source routing, restricted kernel pointers, dmesg, ptrace and unprivileged BPF |
| 9. Swap, limits, logs | A swap file sized to RAM (1 to 4 GB) if there is none, higher open-file limits, journald capped at 1 GB and one month |
| 10. Misc | Core dumps off, `su` limited to the sudo group, home folders private, unused protocols and filesystems blocked, Ctrl-Alt-Del from the provider console ignored |
| 11. Docker (optional) | Docker and Compose from Ubuntu's packages, log rotation, `live-restore`, admin in the `docker` group |

Managed drop-ins have `serverbeef` in their name (`/etc/ssh/sshd_config.d/00-serverbeef.conf`,
`/etc/sysctl.d/90-serverbeef.conf` and so on), so you can see what came from the script. A few shared files, such
as `/etc/hosts`, `/etc/fstab`, UFW defaults and Docker's configuration, also need changes. The settings you chose are
saved in `/etc/serverbeef/state.conf` (never passwords or keys), and the script copies itself to
`/usr/local/sbin/serverbeef`.

## Options

| Flag | Default | Meaning |
|---|---|---|
| `-u, --user NAME` | `deploy` | Admin (sudo) user to create or update |
| `-k, --ssh-key "KEY"` | | Public key for the admin; repeat for several |
| `--no-copy-root-keys` | | Don't copy root's authorized keys to the admin |
| `--sudo-nopasswd` / `--sudo-password` | auto | Passwordless sudo is the default when a key is installed |
| `-p, --ssh-port PORT` | `random` | SSH port; a random free port in 1025-9999 unless you give one |
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

Config files contain literal `NAME=value` assignments, one per line. Use single or double quotes around values
containing spaces; both forms preserve the contents literally. Blank lines and whole-line `#` comments are
allowed. Shell commands, `export`, substitutions, escapes, multiline values and inline comments are not supported.
Only documented settings are accepted. Older config files that used shell scripting must be converted.
Keep config files with passwords private (`chmod 600`) and out of version control.

## Verify mode

`sudo serverbeef --verify` (or the menu on a re-run) changes nothing unless you agree. It checks that SSH listens
on the right port and is key-only, the admin exists with sudo and keys, UFW is active with the ports you chose,
fail2ban jails are running, updates are on, BBR, swap, AppArmor and the clock are fine. It also lists other
accounts that can log in with a password or have sudo rights, such as the `linuxuser` or `ubuntu` account some
provider images leave behind, and prints the command to lock or remove them. It inspects Docker even
when Docker was installed separately, reporting non-loopback published ports and host networking. Routed,
macvlan and ipvlan networks still need a separate review. It offers to delete firewall rules that are not in your settings (such as the
old port 22), then runs a quick Lynis audit and prints the score and warnings.
SSH policy is checked globally and in sampled connection contexts; arbitrary `Match` rules require manual
review. Missing validated admin keys and detected policy failures make verification exit nonzero. Warnings
still require review even when the exit code is zero.

## Things to know

- Docker-published ports bypass UFW. Docker writes its own iptables rules, so `-p 5432:5432` is open to the
  internet whatever UFW says. Bind internal services to localhost (`-p 127.0.0.1:5432:5432`), put a firewall at your
  provider in front of the server, or both. The script warns about this and the verify mode lists exposed ports.
- If your provider has a firewall in front of the server, choose the SSH port before you run the script
  (`--ssh-port 4821`, or let the wizard pick one and note it) and allow it there, or you can't log in on it.
- Port 22 stays open in UFW until you remove it. If your provider added a rule for port 22, the script prints the
  exact delete command, and verify mode offers to remove it once you are logged in on the new port.
- Without an SSH key, password login stays on. So that you can't be locked out, key-only login is turned on only
  when the admin has at least one validated, unrestricted key. Setup reports incomplete and exits nonzero
  otherwise. Restricted keys already in the account remain untouched but do not qualify as an admin login.
  Add an unrestricted personal key and run the script again.
- With a key, sudo needs no password by default, so whoever holds that key is root. Use `--sudo-password` if you
  want sudo to require a password. This is not SSH multifactor authentication; membership in the Docker group
  also grants root-equivalent access and bypasses that sudo password boundary.
- Passwordless admins receive sudo permission directly and use `ssh-users` for SSH. They are removed from
  the `sudo` group because its additional password-required rule makes `sudo -v` prompt on Ubuntu 26.04.
  Use `sudo -i` for a root shell. Password-required admins remain in the `sudo` group. Test from a fresh SSH
  connection after a change so it uses the updated group membership.
- A random SSH port reduces routine scanning noise. It is discoverable and is not an authentication control.
- If this script previously copied restricted root keys, review the admin's `authorized_keys` manually: an older
  version may have removed restrictions. The script cannot safely identify and revoke those keys automatically.
- At the end the script asks `ifconfig.me` for the server's public IP, only to print the right `ssh` command.
- It targets Ubuntu 26.04 on x86_64. It warns on other versions and architectures and refuses non-Ubuntu systems.

## For AI agents

[CLAUDE.md](CLAUDE.md) (also `AGENTS.md`) explains how to run the script on someone's behalf and how to change it
without breaking re-runs or locking anyone out.

## License

MIT, see [LICENSE](LICENSE).
