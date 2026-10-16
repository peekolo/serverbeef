# serverbeef: notes for agents

`serverbeef.sh` hardens a fresh Ubuntu 26.04 x64 VPS (see README.md for what it does). It is one bash file, run as
root on the server. This file covers running it for someone and changing it.

## Running it

1. **Root steps belong to the server's owner.** Running the script needs root and can lock people out of SSH. Do not
   run it on a server unless the owner asked for that server, and say what will change first (new SSH port, key-only
   login, firewall).
2. **Check for a key before anything else.** Key-only login is turned on only if the admin ends up with at least one
   key (from `--ssh-key` or root's `authorized_keys`). Without one, password login stays on and the run prints a
   warning. Don't treat that as success.
3. **Keep the first session open.** SSH moves to port 2222 during the run. Before the session that ran the script is
   closed, someone must log in from a second connection: `ssh -p 2222 <admin>@<ip>`, then `sudo -v`. Never close the
   root session or reboot before that works.
4. **Don't pick `deploy` as the admin out of habit.** It is the default name, but setups that keep a separate
   unprivileged `deploy` user for app deployments need the admin to have a different name. Ask the owner.
5. **Use verify mode to check a server**: `sudo serverbeef --verify`. It only changes something (deleting leftover
   firewall rules) after a yes. In a non-interactive shell, a re-run with no mode flag runs setup again, so pass
   `--verify` explicitly.
6. **Never print, log or commit a generated password.** The script writes it to the terminal only, or to
   `/root/serverbeef-<user>-password.txt` (mode 600) when there is no terminal. Tell the owner where it is; don't
   read it out.

Unattended run:

```bash
ssh -t root@<ip> 'bash serverbeef.sh --yes --user <admin> --ssh-key "<public key>" [--docker] [--udp-ports none]'
```

## Changing the script

The script must stay safe to re-run on a server it already set up, including one set up by an older version.

- Steps are idempotent: each one writes whole files instead of appending, or checks before it appends
  (`grep -q ... || echo ...`). A second run should change nothing.
- Every file the script writes has `$MARK` (`serverbeef`) in its name, and config files start with
  `# Managed by serverbeef.sh`. Use drop-in directories (`*.d/`) instead of editing distro files. When you must
  edit a distro file, make the change with `sed` so it can be applied twice.
- Configs are tested before they are used: sshd config goes through `sshd -t` before SSH is restarted, sudoers
  through `visudo -cf`. A failed test moves the new file aside and stops, so a broken config is never left in place.
- UFW allows the new SSH port before SSH restarts on it. Keep that order.
- A new setting needs a default in the Defaults block (also readable from the environment), a flag in `usage()`
  and the argument parser, a wizard question, and a validator. If it should survive a re-run, add it
  to `STATE_KEYS`. Never add a secret to `STATE_KEYS`.
- A new step needs a check in verify mode (`run_verify`): `vpass` when fine, `vwarn` or `vfail` plus a `vhint`
  with the fix.
- Secrets stay out of the log. All output after the confirmation is copied to `/var/log/serverbeef.log`. Print
  secrets to `/dev/tty` only, as the password box at the end does.
- Prompts read from `/dev/tty` so that `curl ... | sudo bash` keeps working.

Check a change with `bash -n serverbeef.sh` and `shellcheck serverbeef.sh`, then run it on a throwaway Ubuntu 26.04
VM twice (the second run should change nothing) and run `--verify`. Never test on a server that matters.
