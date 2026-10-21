#!/usr/bin/env bash
# shellcheck disable=SC2015  # "A && B || true" is deliberate under set -e
# =============================================================================
#  serverbeef.sh — Harden and tune a fresh Ubuntu 26.04 LTS (x64) VPS for webapps
# =============================================================================
#
#  What it does (each step is idempotent — safe to re-run):
#    1. Full system update + useful base packages
#    2. Hostname / timezone
#    3. Creates a sudo admin user and installs your SSH public key
#    4. Hardens SSH (key-only, no root login, custom port)
#    5. UFW firewall: deny all incoming except SSH + HTTP/HTTPS (configurable)
#    6. Fail2ban with incremental bans + recidive jail
#    7. Unattended security upgrades (optional automatic reboot)
#    8. Kernel/network hardening + performance tuning (BBR, fq, larger queues)
#    9. Swap file (if none), raised file-descriptor limits, journald size cap
#   10. Disables core dumps, ensures AppArmor + time sync are active
#   11. Optional: Docker Engine + Compose with sane log rotation
#
#  Usage (as root, on the server):
#      sudo bash serverbeef.sh                 # interactive wizard
#      sudo bash serverbeef.sh --verify        # check an already set-up server
#      sudo bash serverbeef.sh --help          # all flags
#
#  Re-running it offers a verify mode (checks everything, cleans up leftover
#  firewall rules, runs a Lynis security audit) or a re-run of the setup.
#
#  The wizard asks for every setting. Values given by flag, environment
#  variable or --config file become the wizard's defaults. Pass --yes to skip
#  the wizard and run unattended with those values.
#
#  SAFETY: Password SSH login and root login are only disabled if the admin
#  user ends up with at least one SSH key. Keep your current session open and
#  test logging in from a NEW terminal before disconnecting.
# =============================================================================

# Do not let bash -x / -v copy credentials into a terminal or the setup log.
set +xv
set -Eeuo pipefail
# Config files keep the normal 644 so that tools run by the admin (apt, sysctl, systemd) can read them.
# Secrets get explicit modes: the log and state file 600, the password file 600, the swap file 600.

# ----------------------------- Previous run ----------------------------------
# After a successful run the settings are saved here (never passwords or keys).
# On the next run they become the defaults, unless overridden by env or flags.
STATE_DIR="/etc/serverbeef"
STATE_FILE="$STATE_DIR/state.conf"
STATE_KEYS="ADMIN_USER ADMIN_SUDO_NOPASSWD SSH_PORT SSH_ALLOW_TCP_FORWARDING FIREWALL_TCP_PORTS FIREWALL_UDP_PORTS SWAP_SIZE AUTO_REBOOT AUTO_REBOOT_TIME INSTALL_DOCKER"
SB_PREVIOUS=""        # "", "state" (saved settings) or "inferred" (older version, no state file)
SB_LAST_RUN=""

set_if_unset() { [[ -z "${!1+x}" && -n "$2" ]] && printf -v "$1" '%s' "$2" || true; }

if [[ -r "$STATE_FILE" ]]; then
  SB_PREVIOUS=state
  while IFS= read -r line; do
    [[ "$line" =~ ^([A-Z_]+)=\"([^\"]*)\"$ ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    if [[ "$key" == "SB_LAST_RUN" ]]; then SB_LAST_RUN="$val"
    elif [[ " $STATE_KEYS " == *" $key "* && -z "${!key+x}" ]]; then printf -v "$key" '%s' "$val"   # empty is a real answer (e.g. no UDP ports)
    fi
  done < "$STATE_FILE"
elif [[ -f /etc/ssh/sshd_config.d/00-serverbeef.conf ]]; then
  # Ran with an older version that didn't save settings: read them off the system.
  SB_PREVIOUS=inferred
  SB_LAST_RUN="$(date -r /etc/ssh/sshd_config.d/00-serverbeef.conf '+%Y-%m-%d %H:%M' 2>/dev/null || echo unknown)"
  set_if_unset SSH_PORT "$(awk '$1=="Port"{print $2; exit}' /etc/ssh/sshd_config.d/00-serverbeef.conf)"
  inferred_user="$(find /etc/sudoers.d -maxdepth 1 -name '90-serverbeef-*' -printf '%f\n' 2>/dev/null | head -1 | sed 's/^90-serverbeef-//')"
  if [[ -n "$inferred_user" ]]; then
    set_if_unset ADMIN_SUDO_NOPASSWD yes
  else
    inferred_user="$(getent group sudo | cut -d: -f4 | tr ',' '\n' | grep -vx root | head -1)"
  fi
  set_if_unset ADMIN_USER "$inferred_user"
  if [[ $EUID -eq 0 ]] && command -v ufw >/dev/null; then
    # An empty result means "no ports", so don't let the built-in default fill it in
    [[ -n "${FIREWALL_TCP_PORTS+x}" ]] || FIREWALL_TCP_PORTS="$(ufw show added 2>/dev/null | sed -nE "s/^ufw allow ([0-9:]+)\/tcp comment 'public'$/\1/p" | xargs)"
    [[ -n "${FIREWALL_UDP_PORTS+x}" ]] || FIREWALL_UDP_PORTS="$(ufw show added 2>/dev/null | sed -nE "s/^ufw allow ([0-9:]+)\/udp comment 'public'$/\1/p" | xargs)"
  fi
  command -v docker >/dev/null && set_if_unset INSTALL_DOCKER yes || true
  grep -q 'Automatic-Reboot "false"' /etc/apt/apt.conf.d/52serverbeef-unattended-upgrades 2>/dev/null && set_if_unset AUTO_REBOOT no || true
fi

# ----------------------------- Defaults --------------------------------------
# Any of these can also be set as environment variables or in a --config file.
ADMIN_USER="${ADMIN_USER:-deploy}"              # sudo user to create/configure
ADMIN_SSH_KEY="${ADMIN_SSH_KEY:-}"              # public key(s), one per line
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"            # sudo password (prefer the wizard over this)
ADMIN_SUDO_NOPASSWD="${ADMIN_SUDO_NOPASSWD:-auto}" # yes | no | auto (yes if the user has an SSH key)
GENERATE_PASSWORD="${GENERATE_PASSWORD:-no}"    # set by the wizard when you accept [auto-generate]
COPY_ROOT_KEYS="${COPY_ROOT_KEYS:-yes}"         # copy root's authorized_keys to the admin user

SSH_PORT="${SSH_PORT:-}"                        # empty or "random": a random free port in 1025-9999 (per server)
SSH_ALLOW_TCP_FORWARDING="${SSH_ALLOW_TCP_FORWARDING:-local}" # no | local | yes  (local keeps `ssh -L` DB tunnels working)

FIREWALL_TCP_PORTS="${FIREWALL_TCP_PORTS-80 443}"   # extra public TCP ports (SSH is added automatically); empty = none
FIREWALL_UDP_PORTS="${FIREWALL_UDP_PORTS-443}"      # 443/udp for HTTP/3 (QUIC); empty = none

SET_HOSTNAME="${SET_HOSTNAME:-}"                # e.g. web01.example.com; empty = leave unchanged
TIMEZONE="${TIMEZONE:-}"                        # e.g. UTC; empty = leave unchanged

SWAP_SIZE="${SWAP_SIZE:-auto}"                  # auto | none | e.g. 2G
AUTO_REBOOT="${AUTO_REBOOT:-yes}"               # reboot automatically when security updates require it
AUTO_REBOOT_TIME="${AUTO_REBOOT_TIME:-04:00}"

INSTALL_DOCKER="${INSTALL_DOCKER:-no}"          # yes | no
ASSUME_YES="${ASSUME_YES:-no}"
MODE=""                                         # "" (ask) | setup | verify

LOG_FILE="/var/log/serverbeef.log"
MARK="serverbeef"                               # prefix for every config file we write

usage() {
  cat <<'EOF'
serverbeef.sh — harden and tune a fresh Ubuntu 26.04 LTS VPS for webapps

Usage: sudo bash serverbeef.sh [options]

Without --yes, an interactive wizard asks for every setting below, using any
flags you pass as its defaults.

Options:
  -u, --user NAME            Admin (sudo) user to create          [deploy]
  -k, --ssh-key "KEY"        Public SSH key for the admin user (repeatable)
      --no-copy-root-keys    Don't copy root's authorized_keys to the admin user
      --sudo-nopasswd        Passwordless sudo (default if a key is installed)
      --sudo-password        Require a password for sudo (generated if none set)
  -p, --ssh-port PORT        SSH port, or "random"                [random]
      --forwarding MODE      SSH TCP forwarding: no|local|yes     [local]
      --tcp-ports "P ..."    Public TCP ports (besides SSH)       ["80 443"]
      --udp-ports "P ..."    Public UDP ports, "none" to disable  ["443"]
      --hostname NAME        Set hostname                         [current]
      --timezone TZ          Set timezone, e.g. UTC               [current]
      --swap SIZE            Swap file size: auto|none|2G|...     [auto]
      --auto-reboot          Reboot automatically after updates (default)
      --no-auto-reboot       Never reboot automatically
      --reboot-time HH:MM    Time for automatic reboots           [04:00]
      --docker               Install Docker + Compose
      --no-docker            Don't install Docker (default)
      --verify               Check an already set-up server (and offer fixes)
      --setup                Skip the menu and go straight to setup on re-runs
  -c, --config FILE          Load settings from a file (VAR=value lines)
  -y, --yes                  Skip the wizard; run unattended with given values
  -h, --help                 Show this help

After a successful run, settings are saved to /etc/serverbeef/state.conf.
Running the script again offers to verify the setup or to re-run it with
those settings as defaults.

Every option can also be set as an environment variable, e.g. SSH_PORT=2200.
The sudo password can be given as ADMIN_PASSWORD for unattended runs.
EOF
}

# ----------------------------- CLI args --------------------------------------
# Config files are data, never shell programs. Quotes only delimit a literal
# value; expansion, escapes, inline comments and shell statements are unsupported.
load_config() {
  local file="$1" line name value line_no=0
  local allowed=" $STATE_KEYS ADMIN_SSH_KEY ADMIN_PASSWORD GENERATE_PASSWORD COPY_ROOT_KEYS SET_HOSTNAME TIMEZONE ASSUME_YES "
  [[ -f "$file" && -r "$file" ]] || { echo "Cannot read config file" >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    if [[ ! "$line" =~ ^([A-Z_]+)=(.*)$ ]]; then
      echo "Invalid config assignment at line $line_no" >&2; return 1
    fi
    name="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    if [[ "$allowed" != *" $name "* ]]; then
      echo "Unsupported config setting at line $line_no" >&2; return 1
    fi
    case "$value" in
      \"|\') echo "Unbalanced quote at line $line_no" >&2; return 1 ;;
      \"*\") value="${value:1:${#value}-2}" ;;
      \'*\') value="${value:1:${#value}-2}" ;;
      *[[:space:]\"\']*) echo "Quote config values containing spaces (line $line_no)" >&2; return 1 ;;
    esac
    printf -v "$name" '%s' "$value"
  done < "$file"
}
need_arg() { [[ $# -ge 2 && -n "$2" ]] || { echo "Option $1 needs a value" >&2; exit 1; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)            need_arg "$@"; ADMIN_USER="$2"; shift 2 ;;
    -k|--ssh-key)         need_arg "$@"; ADMIN_SSH_KEY+="${ADMIN_SSH_KEY:+$'\n'}$2"; shift 2 ;;
    --no-copy-root-keys)  COPY_ROOT_KEYS=no; shift ;;
    --sudo-nopasswd)      ADMIN_SUDO_NOPASSWD=yes; shift ;;
    --sudo-password)      ADMIN_SUDO_NOPASSWD=no; shift ;;
    -p|--ssh-port)        need_arg "$@"; SSH_PORT="$2"; shift 2 ;;
    --forwarding)         need_arg "$@"; SSH_ALLOW_TCP_FORWARDING="$2"; shift 2 ;;
    --tcp-ports)          need_arg "$@"; FIREWALL_TCP_PORTS="$2"; shift 2 ;;
    --udp-ports)          need_arg "$@"; FIREWALL_UDP_PORTS="$2"; shift 2 ;;
    --hostname)           need_arg "$@"; SET_HOSTNAME="$2"; shift 2 ;;
    --timezone)           need_arg "$@"; TIMEZONE="$2"; shift 2 ;;
    --swap)               need_arg "$@"; SWAP_SIZE="$2"; shift 2 ;;
    --auto-reboot)        AUTO_REBOOT=yes; shift ;;
    --no-auto-reboot)     AUTO_REBOOT=no; shift ;;
    --reboot-time)        need_arg "$@"; AUTO_REBOOT_TIME="$2"; shift 2 ;;
    --docker)             INSTALL_DOCKER=yes; shift ;;
    --no-docker)          INSTALL_DOCKER=no; shift ;;
    -c|--config)          need_arg "$@"
                          load_config "$2" || exit 1; shift 2 ;;
    --verify)             MODE=verify; shift ;;
    --setup)              MODE=setup; shift ;;
    -y|--yes|--non-interactive) ASSUME_YES=yes; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) echo "Unknown option: $1 (see --help)" >&2; exit 1 ;;
  esac
done

# Keep a password supplied through the environment out of child processes.
export -n ADMIN_PASSWORD

# ----------------------------- SSH port --------------------------------------
# No fixed default: a port every server shares is a port every scanner tries first. Below 10000 because
# net.ipv4.ip_local_port_range (step 8) hands out 10000-65535 to outgoing connections.
SSH_PORT_RANDOM=no
random_port() {
  local p common=" 1080 1433 1521 2049 2375 2376 2377 2222 3000 3001 3306 3389 4000 4200 4443 5000 5173 5432 5672 5900 5984 6379 6443 7000 7001 8000 8008 8080 8081 8088 8443 8888 9000 9042 9090 9092 9100 9200 9300 9418 9443 "
  while true; do
    p=$(( 1025 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 8975 ))
    [[ "$common" == *" $p "* ]] && continue
    ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p$" && continue
    echo "$p"; return
  done
}
if [[ -z "$SSH_PORT" || "${SSH_PORT,,}" == "random" ]]; then
  SSH_PORT="$(random_port)"; SSH_PORT_RANDOM=yes
fi

# ----------------------------- Helpers ---------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_BLUE=$'\e[1;34m'; C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=
fi
step() { echo; echo "${C_BLUE}==> $*${C_RESET}"; }
ok()   { echo "${C_GREEN}  ✔ $*${C_RESET}"; }
warn() { echo "${C_YELLOW}  ! $*${C_RESET}"; WARNINGS+=("$*"); }
die()  { echo "${C_RED}  ✘ $*${C_RESET}" >&2; exit 1; }
WARNINGS=()
GENERATED_PASSWORD=""

# shellcheck disable=SC2120  # the directory argument is for the tests
deliver_generated_password() {
  local directory="${1:-/root}" file temp
  # Deliver before changing the account, so a later failure cannot lose it.
  # /dev/tty bypasses the tee logger; unattended credentials use an atomic file.
  if { printf '\nGenerated password for %s — save it now in your password manager:\n%s\n\n' \
    "$ADMIN_USER" "$GENERATED_PASSWORD" > /dev/tty; } 2>/dev/null; then
    return
  fi
  file="$directory/${MARK}-${ADMIN_USER}-password.txt"
  temp="$(mktemp "$directory/${MARK}-password.XXXXXX")"
  printf '%s\n' "$GENERATED_PASSWORD" > "$temp"
  chmod 600 "$temp"
  mv -fT "$temp" "$file"
  echo "Generated credential saved to $file (root-only); save it securely and delete that file."
}

# Commands and their arguments can contain passwords. Log only the location.
trap 'die "Failed at line $LINENO (see $LOG_FILE)"' ERR

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
APT_OPTS=(-y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Normalise "none"/"-" to empty, and yes/no-ish values to yes|no
none_to_empty() { [[ "${1,,}" == "none" || "$1" == "-" ]] && echo "" || echo "$1"; }
yesno() { case "${1,,}" in y|yes|true|1) echo yes ;; n|no|false|0) echo no ;; *) echo "$1" ;; esac; }

# ----------------------------- Validators ------------------------------------
valid_user()       { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != "root" ]]; }
valid_port()       { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
valid_ports() {
  local p start end
  [[ "$1" =~ ^[0-9:[:space:]]*$ ]] || return 1
  for p in $1; do
    valid_port "$p" && continue
    [[ "$p" =~ ^([0-9]+):([0-9]+)$ ]] || return 1
    start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    valid_port "$start" && valid_port "$end" && (( 10#$start < 10#$end )) || return 1
  done
}
valid_hostname()   { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; }
valid_timezone()   { [[ -z "$1" || ( "$1" != *..* && -f "/usr/share/zoneinfo/$1" ) ]]; }
valid_swap()       { [[ "$1" =~ ^(auto|none|[0-9]+[MG])$ ]]; }
valid_time()       { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
valid_yesno()      { [[ "$1" == "yes" || "$1" == "no" ]]; }
valid_forwarding() { [[ "$1" =~ ^(no|local|yes)$ ]]; }
valid_sshkey() {
  [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]] || return 1
  [[ "$1" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+)\ [A-Za-z0-9+/=]+ ]] || return 1
  command -v ssh-keygen >/dev/null || return 1
  ssh-keygen -l -f - <<< "$1" >/dev/null 2>&1
}

valid_password() { [[ "$1" != *$'\n'* && "$1" != *$'\r'* ]]; }

# ----------------------------- Wizard ----------------------------------------
# Prompts read from /dev/tty so `curl ... | sudo bash` still works.
INTERACTIVE=no
if [[ "$ASSUME_YES" != "yes" ]] && { : < /dev/tty; } 2>/dev/null; then INTERACTIVE=yes; fi

# ask VAR "Question" validator [hint]
ask() {
  local __var="$1" __q="$2" __check="$3" __hint="${4:-}" __ans __def
  __def="${!__var}"
  while true; do
    [[ -n "$__hint" ]] && echo "    ${C_DIM}${__hint}${C_RESET}" > /dev/tty || true
    read -r -p "  ${C_BOLD}${__q}${C_RESET} [${__def:-none}]: " __ans < /dev/tty || __ans=""
    __ans="${__ans:-$__def}"
    __ans="$(none_to_empty "$__ans")"
    if "$__check" "$__ans"; then printf -v "$__var" '%s' "$__ans"; return 0; fi
    echo "    ${C_RED}Invalid value, try again.${C_RESET}" > /dev/tty
    __hint=""
  done
}
# ask_yn VAR "Question?"
ask_yn() {
  local __var="$1" __q="$2" __ans __def
  __def="$(yesno "${!__var}")"
  while true; do
    read -r -p "  ${C_BOLD}${__q}${C_RESET} [$([[ "$__def" == yes ]] && echo Y/n || echo y/N)]: " __ans < /dev/tty || __ans=""
    __ans="$(yesno "${__ans:-$__def}")"
    if valid_yesno "$__ans"; then printf -v "$__var" '%s' "$__ans"; return 0; fi
  done
}
section() { echo; echo "${C_BLUE}── $* ${C_RESET}"; }

[[ $EUID -eq 0 ]] || die "Run as root (e.g. sudo bash serverbeef.sh)"

# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  die "This script targets Ubuntu (detected: ${PRETTY_NAME:-unknown})"
fi
if [[ "${VERSION_ID:-}" != "26.04" ]]; then
  echo "${C_YELLOW}Warning: written for Ubuntu 26.04, detected ${PRETTY_NAME}.${C_RESET}"
fi
[[ "$(uname -m)" == "x86_64" ]] || echo "${C_YELLOW}Warning: written for x86_64, detected $(uname -m).${C_RESET}"

# Never strip authorized_keys options: a forced-command backup key must not
# become an unrestricted sudo login. Only bare, validated keys qualify here.
extract_key() { if valid_sshkey "$1"; then printf '%s\n' "$1"; fi; }
# "ED25519  SHA256:...  comment"
key_fingerprint() {
  local fp
  fp="$(ssh-keygen -l -f - <<< "$1" 2>/dev/null)" || { echo "${1:0:40}..."; return; }
  awk '{t=$NF; gsub(/[()]/,"",t); c=""; for(i=3;i<NF;i++) c=c (c?" ":"") $i; printf "%-8s %s  %s\n", t, $2, c}' <<< "$fp"
}
count_keys() {
  local line count=0
  if [[ -r "$1" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      if valid_sshkey "$line"; then count=$((count + 1)); fi
    done < "$1"
  fi
  echo "$count"
}

# Evaluate global policy and representative Match contexts. This is not a proof
# about every possible Match Address/Host rule; verify reports that limitation.
ssh_policy_ok() {
  local cfg user addr context
  local -a contexts=("")
  for user in "$ADMIN_USER" root; do
    for addr in 198.51.100.1 2001:db8::1; do
      contexts+=("user=$user,host=serverbeef-check.invalid,addr=$addr,laddr=127.0.0.1,lport=$SSH_PORT")
    done
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      local client_ip server_ip
      read -r client_ip _ server_ip _ <<< "$SSH_CONNECTION"
      contexts+=("user=$user,host=$client_ip,addr=$client_ip,laddr=$server_ip,lport=$SSH_PORT")
    fi
  done
  for context in "${contexts[@]}"; do
    if [[ -n "$context" ]]; then
      cfg="$(sshd -T -C "$context")" || return 1
    else
      cfg="$(sshd -T)" || return 1
      [[ "$(awk '$1=="port"{print $2}' <<< "$cfg")" == "$SSH_PORT" ]] || return 1
    fi
    grep -qx 'pubkeyauthentication yes' <<< "$cfg" || return 1
    grep -qx 'kbdinteractiveauthentication no' <<< "$cfg" || return 1
    if [[ "$HAVE_KEYS" == yes ]]; then
      grep -qx 'passwordauthentication no' <<< "$cfg" || return 1
      grep -qx 'permitrootlogin no' <<< "$cfg" || return 1
      grep -qx 'authenticationmethods publickey' <<< "$cfg" || return 1
    else
      grep -qx 'passwordauthentication yes' <<< "$cfg" || return 1
      grep -qxE 'permitrootlogin (prohibit-password|without-password|no)' <<< "$cfg" || return 1
    fi
  done
}

# ============================================================================
#  Verify mode — checks a server this script already set up
# ============================================================================
V_PASS=0; V_WARN=0; V_FAIL=0
vpass() { echo "  ${C_GREEN}✔${C_RESET} $*"; V_PASS=$((V_PASS + 1)); }
vwarn() { echo "  ${C_YELLOW}!${C_RESET} $*"; V_WARN=$((V_WARN + 1)); }
vfail() { echo "  ${C_RED}✘${C_RESET} $*"; V_FAIL=$((V_FAIL + 1)); }
vhint() { echo "      ${C_DIM}→ $*${C_RESET}"; }

# The server-side port the current SSH session came in on ("" if not over SSH).
# sudo drops $SSH_CONNECTION, so fall back to walking up to our sshd process.
session_port() {
  if [[ -n "${SSH_CONNECTION:-}" ]]; then awk '{print $4}' <<< "$SSH_CONNECTION"; return; fi
  local pid=$$ comm
  while [[ -n "$pid" ]] && (( pid > 1 )); do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null || true)"
    if [[ "$comm" == sshd* ]]; then
      ss -tnpH state established 2>/dev/null | grep -F "pid=$pid," | awk '{print $3}' | sed 's/.*://' | head -1
      return
    fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  done
}

run_lynis() {
  command -v lynis >/dev/null || apt-get install -y -q lynis >/dev/null
  local report=/var/log/lynis-report.dat out=/var/log/serverbeef-lynis.log score warnings suggestions
  echo "  Running Lynis (takes 1–2 minutes)..."
  lynis audit system --quick --no-colors > "$out" 2>&1 || true
  score="$(awk -F= '$1=="hardening_index"{print $2}' "$report" 2>/dev/null)"
  warnings="$(grep -c '^warning\[\]=' "$report" 2>/dev/null || true)"
  suggestions="$(grep -c '^suggestion\[\]=' "$report" 2>/dev/null || true)"
  echo
  if [[ -z "$score" ]]; then
    vwarn "Lynis did not produce a report — see $out"
    return
  fi
  if (( score >= 75 )); then vpass "Lynis hardening score: ${C_BOLD}$score/100${C_RESET} (good)"
  elif (( score >= 60 )); then vpass "Lynis hardening score: ${C_BOLD}$score/100${C_RESET} (decent — typical for a hardened web server)"
  else vwarn "Lynis hardening score: ${C_BOLD}$score/100${C_RESET} (needs work)"
  fi
  vhint "Lynis is strict; 100 is not the goal. Its suggestions are optional extra hardening."
  if (( ${warnings:-0} > 0 )); then
    vwarn "Lynis found $warnings warning(s):"
    grep '^warning\[\]=' "$report" | cut -d'|' -f1,2 | sed -E 's/^warning\[\]=/        /; s/\|/  /'
  else
    vpass "Lynis found no warnings"
  fi
  vhint "$suggestions suggestion(s). Full output: $out  ·  Report: $report"
}

automatic_updates_enabled() {
  local apt_settings
  systemctl is-enabled --quiet unattended-upgrades 2>/dev/null || return 1
  apt_settings="$(apt-config dump)" || return 1
  # Read the complete output before matching: grep -q in a pipe can make
  # apt-config exit on SIGPIPE under pipefail and report a false failure.
  grep -qx 'APT::Periodic::Update-Package-Lists "1";' <<< "$apt_settings" || return 1
  grep -qx 'APT::Periodic::Unattended-Upgrade "1";' <<< "$apt_settings" || return 1
  ! grep -qx 'APT::Periodic::Enable "0";' <<< "$apt_settings"
}

run_verify() {
  local user_home keys sshd_cfg p rule token port
  echo
  echo "${C_BLUE}serverbeef — verifying this server${C_RESET}  (last setup: ${SB_LAST_RUN:-unknown})"

  section "SSH"
  if ss -tlnH | awk '{print $4}' | grep -qE "[:.]${SSH_PORT}$"; then vpass "SSH is listening on port $SSH_PORT"
  else vfail "SSH is NOT listening on port $SSH_PORT"; vhint "Check: sudo ss -tlnp | grep ssh"
  fi
  sshd_cfg="$(sshd -T 2>/dev/null || true)"
  user_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)"
  keys="$( [[ -n "$user_home" ]] && count_keys "$user_home/.ssh/authorized_keys" || echo 0)"
  keys="${keys:-0}"
  if (( keys > 0 )); then
    if grep -qx 'passwordauthentication no' <<< "$sshd_cfg"; then vpass "Password login is off (key-only)"
    else vfail "Password login is ON even though $ADMIN_USER has a key"; vhint "Choose 'Run setup again' to fix"
    fi
    if grep -qx 'permitrootlogin no' <<< "$sshd_cfg"; then vpass "Root login is off"
    else vfail "Root login is allowed ($(awk '$1=="permitrootlogin"{print $2}' <<< "$sshd_cfg"))"; vhint "Review SSH configuration before re-running setup"
    fi
  else
    vfail "$ADMIN_USER has no validated, unrestricted SSH key"
    vhint "Install and test a personal admin key before enabling key-only login"
  fi
  HAVE_KEYS=no; (( keys > 0 )) && HAVE_KEYS=yes
  if sshd -t && ssh_policy_ok; then
    vpass "Effective SSH policy matches in global and sampled connection contexts"
  else
    vfail "Effective SSH policy differs from the intended settings"
    vhint "Inspect sudo sshd -T and sudo sshd -T -C user=$ADMIN_USER,host=CLIENT,addr=CLIENT_IP"
  fi
  if grep -Eq '^[[:space:]]*Match[[:space:]]' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null; then
    vwarn "SSH Match rules exist; sampled checks cannot cover every source address or hostname"
    vhint "Review all included SSH files and test each intended login path"
  fi

  section "Admin user"
  if [[ -n "$user_home" ]]; then
    vpass "User $ADMIN_USER exists"
    if [[ "$ADMIN_SUDO_NOPASSWD" == yes ]]; then
      if runuser -u "$ADMIN_USER" -- sudo -n -v && runuser -u "$ADMIN_USER" -- sudo -n true; then
        vpass "$ADMIN_USER can validate and execute passwordless sudo"
      else
        vfail "$ADMIN_USER's passwordless sudo policy is not effective"
        vhint "Review sudo -l -U $ADMIN_USER and other sudoers rules for this user"
      fi
    elif id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx sudo; then vpass "$ADMIN_USER has sudo"
    else vfail "$ADMIN_USER is not in the sudo group"; vhint "Fix: usermod -aG sudo $ADMIN_USER"
    fi
    (( keys > 0 )) && vpass "$ADMIN_USER has $keys SSH key(s)" || true
  else
    vfail "User $ADMIN_USER does not exist"
  fi

  section "Other accounts"
  # Provider images often leave a second sudo account behind (Vultr's "linuxuser", cloud images' "ubuntu").
  # Such an account with a password or sudo rights is a login path the owner may not know about.
  local other others=0 status
  while IFS=: read -r other _ uid _ _ _ shell; do
    [[ "$other" == "$ADMIN_USER" || "$shell" == */nologin || "$shell" == */false ]] && continue
    (( uid >= 1000 || uid == 0 )) || continue
    status="$(passwd -S "$other" 2>/dev/null | awk '{print $2}')"
    if [[ "$status" == P ]]; then
      others=$((others + 1)); vwarn "$other can log in with a password"
      vhint "Lock it if it is a leftover provider account: sudo passwd -l $other"
    fi
    if [[ "$other" != root ]] && { id -nG "$other" 2>/dev/null | tr ' ' '\n' | grep -qxE 'sudo|admin' \
         || grep -qsE "^[[:space:]]*${other}[[:space:]]" /etc/sudoers /etc/sudoers.d/*; }; then
      others=$((others + 1)); vwarn "$other also has sudo rights"
      vhint "Remove it if nobody uses it: sudo deluser --remove-home $other"
    fi
  done < /etc/passwd
  (( others == 0 )) && vpass "No other account with a password or sudo rights" || true

  section "Firewall"
  if ufw status 2>/dev/null | grep -q '^Status: active'; then vpass "UFW is active"
  else vfail "UFW is NOT active"; vhint "Choose 'Run setup again' to fix"
  fi
  if ufw status verbose 2>/dev/null | grep -q 'Default: deny (incoming), allow (outgoing), deny (routed)'; then
    vpass "UFW default policy denies incoming and routed traffic"
  else
    vfail "UFW default policy differs from the intended deny policy"; vhint "Review sudo ufw status verbose"
  fi
  if grep -qx 'IPV6=yes' /etc/default/ufw; then
    vpass "UFW manages IPv6"
  else
    vfail "UFW IPv6 protection is disabled"; vhint "Enable IPV6=yes in /etc/default/ufw and reload UFW after checking SSH access"
  fi
  # Simple rules only ("ufw allow 80/tcp"); rules with from/to addresses are left alone.
  local -a rules=() expected=("$SSH_PORT/tcp")
  for p in $FIREWALL_TCP_PORTS; do expected+=("$p/tcp"); done
  for p in $FIREWALL_UDP_PORTS; do expected+=("$p/udp"); done
  mapfile -t rules < <(ufw show added 2>/dev/null | grep -E '^ufw (allow|limit)( in)? [^ ]+( comment .*)?$' | sed -E 's/ comment .*//' || true)
  local -A have=()
  for rule in "${rules[@]}"; do
    token="${rule##* }"; [[ "$token" == "OpenSSH" ]] && token="22/tcp"
    if [[ "$token" == */* ]]; then have["$token"]=1; else have["$token/tcp"]=1; have["$token/udp"]=1; fi
  done
  for p in "${expected[@]}"; do
    if [[ -n "${have[$p]:-}" ]]; then vpass "Port $p is open"
    else vfail "Port $p should be open but isn't"; vhint "Fix: sudo ufw allow $p"
    fi
  done

  # Leftover rules: open ports that aren't in your settings (e.g. old SSH port 22)
  local sport stale=0 answer
  sport="$(session_port || true)"
  for rule in "${rules[@]}"; do
    token="${rule##* }"; [[ "$token" == "OpenSSH" ]] && token="22/tcp"
    if [[ "$token" == */* ]]; then
      printf '%s\n' "${expected[@]}" | grep -qxF "$token" && continue
    else
      printf '%s\n' "${expected[@]}" | grep -qxE "$token/(tcp|udp)" && continue
    fi
    stale=$((stale + 1))
    port="${token%%/*}"
    vwarn "Leftover rule: '${rule#ufw }' — not in your settings"
    [[ "$INTERACTIVE" == "yes" ]] || { vhint "Remove with: sudo ${rule/#ufw /ufw delete }"; continue; }
    if [[ -n "$sport" && "$port" == "$sport" ]]; then
      vhint "Not removing: your current SSH session is connected through port $port."
      vhint "Reconnect with: ssh -p $SSH_PORT $ADMIN_USER@<server>  — then run verify again."
      continue
    fi
    answer=yes
    if [[ "$port" == "22" && -z "$sport" ]]; then
      vhint "Couldn't tell which port this session uses. Only remove this if you've confirmed SSH works on port $SSH_PORT."
      answer=no
    elif [[ "$port" == "22" ]]; then
      vhint "You're connected on port $sport, so SSH on the new port works — safe to remove."
    fi
    ask_yn answer "Remove it?"
    if [[ "$answer" == "yes" ]]; then
      local -a del_args
      read -ra del_args <<< "${rule#ufw }"
      if ufw --force delete "${del_args[@]}" >/dev/null 2>&1; then
        vpass "Removed '${rule#ufw }'"; stale=$((stale - 1)); V_WARN=$((V_WARN - 1))
      else
        vfail "Could not remove '${rule#ufw }'"
      fi
    fi
  done
  (( stale == 0 )) && (( ${#rules[@]} > 0 )) && vpass "No leftover firewall rules" || true

  section "Fail2ban"
  if systemctl is-active --quiet fail2ban; then
    vpass "Fail2ban is running"
    local jail banned
    for jail in sshd recidive; do
      if banned="$(fail2ban-client status "$jail" 2>/dev/null | awk -F'\t' '/Currently banned/{print $2}')" && [[ -n "$banned" ]]; then
        vpass "Jail '$jail' active — $banned IP(s) currently banned"
      else
        vfail "Jail '$jail' is not active"; vhint "Check: sudo journalctl -u fail2ban"
      fi
    done
  else
    vfail "Fail2ban is NOT running"; vhint "Check: sudo journalctl -u fail2ban"
  fi

  section "Updates"
  if automatic_updates_enabled; then
    vpass "Automatic security updates are on (auto-reboot: $AUTO_REBOOT$([[ "$AUTO_REBOOT" == yes ]] && echo " at $AUTO_REBOOT_TIME"))"
  else
    vfail "Automatic security updates are NOT on"
    vhint "Review apt-config dump and systemctl status apt-daily-upgrade.timer unattended-upgrades"
  fi
  if [[ -f /var/run/reboot-required ]]; then
    vwarn "A reboot is pending to finish installing updates"; vhint "Run: sudo reboot"
  else
    vpass "No reboot pending"
  fi

  section "System"
  if [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]]; then
    vpass "BBR congestion control is active"
  else vwarn "BBR is not active"; vhint "Check sysctl net.ipv4.tcp_congestion_control"
  fi
  if [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then vpass "Swap: $(swapon --show --noheadings | awk '{print $1" "$3}' | head -1)"
  elif [[ "$SWAP_SIZE" == "none" ]]; then vpass "No swap (as configured)"
  else vwarn "No swap is active"
  fi
  if aa-status --enabled 2>/dev/null; then vpass "AppArmor is enabled"
  else vwarn "AppArmor is not enabled"; vhint "Check sudo aa-status"
  fi
  if [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then vpass "Clock is synced"
  else vwarn "Clock is not synced yet"; vhint "Check timedatectl"
  fi

  if command -v docker >/dev/null; then
    section "Docker"
    if systemctl is-active --quiet docker; then
      vpass "Docker is running"
      local containers container details
      if ! containers="$(docker ps -q)"; then
        vfail "Could not inspect Docker containers"; vhint "Check sudo docker ps"
      else
        for container in $containers; do
          if ! details="$(docker inspect "$container" | jq -r '
            .[] | .Name as $name |
            (if .HostConfig.NetworkMode == "host" then "\($name): host networking" else empty end),
            ((.NetworkSettings.Ports // {}) | to_entries[] | .value[]? |
              select((.HostIp | startswith("127.")) == false and .HostIp != "::1") |
              "\($name): \(.HostIp):\(.HostPort)")')"; then
            vfail "Could not inspect a Docker network binding"; vhint "Review sudo docker inspect $container"
            continue
          fi
          if [[ -n "$details" ]]; then
            vwarn "Docker has non-loopback port bindings or host networking:"
            printf '        %s\n' "$details"
            vhint "Check provider firewall and container networks; use localhost bindings for internal services"
          fi
        done
        vhint "Published ports can bypass UFW. Also review routed, macvlan and ipvlan networks."
      fi
    else
      if [[ "$INSTALL_DOCKER" == yes ]]; then
        vfail "Docker is NOT running"; vhint "Check sudo systemctl status docker"
      else
        vpass "Docker is installed but inactive"
      fi
    fi
  elif [[ "$INSTALL_DOCKER" == yes ]]; then
    vfail "Docker is configured but not installed"; vhint "Re-run setup with --docker"
  fi

  section "Security audit"
  local do_lynis=yes
  if [[ "$INTERACTIVE" == "yes" ]]; then
    ask_yn do_lynis "Run the Lynis security audit now? (1–2 minutes)"
  else
    do_lynis=no; vhint "Skipped in non-interactive mode. Run: sudo lynis audit system"
  fi
  [[ "$do_lynis" == "yes" ]] && run_lynis || true

  echo
  echo "${C_BLUE}─────────────────────────────────────────────${C_RESET}"
  echo "  ${C_GREEN}$V_PASS passed${C_RESET} · ${C_YELLOW}$V_WARN warning(s)${C_RESET} · ${C_RED}$V_FAIL problem(s)${C_RESET}"
  echo "${C_BLUE}─────────────────────────────────────────────${C_RESET}"
  echo "$(date -Is) verify: $V_PASS passed, $V_WARN warnings, $V_FAIL problems" >> "$LOG_FILE"
  (( V_FAIL == 0 ))
}

# ----------------------------- Mode ------------------------------------------
if [[ -n "$SB_PREVIOUS" && -z "$MODE" ]]; then
  if [[ "$INTERACTIVE" == "yes" ]]; then
    echo
    echo "${C_BLUE}serverbeef already ran on this server${C_RESET} (${SB_LAST_RUN:-unknown})."
    echo
    echo "  1) Verify setup      — check everything is still correct"
    echo "  2) Run setup again   — change settings (your previous answers are the defaults)"
    echo "  3) Exit"
    while true; do
      read -r -p "  ${C_BOLD}Choose${C_RESET} [1]: " choice < /dev/tty || choice=""
      case "${choice:-1}" in
        1) MODE=verify; break ;;
        2) MODE=setup; break ;;
        3) exit 0 ;;
      esac
    done
  else
    MODE=setup
  fi
fi
if [[ "$MODE" == "verify" ]]; then
  [[ -n "$SB_PREVIOUS" ]] || die "serverbeef hasn't set up this server yet — run it without --verify first."
  [[ "$SB_PREVIOUS" == "inferred" ]] && echo "  ${C_DIM}(No saved settings from an older version — read them from the system.)${C_RESET}" || true
  FIREWALL_TCP_PORTS="$(none_to_empty "$FIREWALL_TCP_PORTS")"
  FIREWALL_UDP_PORTS="$(none_to_empty "$FIREWALL_UDP_PORTS")"
  if ! valid_user "$ADMIN_USER" || ! valid_port "$SSH_PORT" \
    || ! valid_ports "$FIREWALL_TCP_PORTS" || ! valid_ports "$FIREWALL_UDP_PORTS"; then
    die "Invalid saved verification settings; review $STATE_FILE"
  fi
  run_verify && exit 0 || exit 1
fi

ROOT_KEYS=()
ROOT_KEYS_SKIPPED=0
if [[ -s /root/.ssh/authorized_keys ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    k="$(extract_key "$line")"
    if [[ -n "$k" ]]; then ROOT_KEYS+=("$k")
    elif [[ ! "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then ROOT_KEYS_SKIPPED=$((ROOT_KEYS_SKIPPED + 1))
    fi
  done < /root/.ssh/authorized_keys
fi
ROOT_KEY_COUNT=${#ROOT_KEYS[@]}
if (( ROOT_KEYS_SKIPPED > 0 )); then
  warn "Skipped $ROOT_KEYS_SKIPPED restricted or invalid root key line(s). Supply an unrestricted personal admin public key with --ssh-key."
fi

CURRENT_HOSTNAME="$(hostname)"
CURRENT_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)"
valid_timezone "$CURRENT_TZ" || CURRENT_TZ="UTC"   # never offer a default the wizard would reject

if [[ "$INTERACTIVE" == "yes" ]]; then
  cat <<EOF

${C_BLUE}┌──────────────────────────────────────────────────────────┐
│  serverbeef — VPS hardening & tuning for Ubuntu 26.04    │
└──────────────────────────────────────────────────────────┘${C_RESET}
  Every question has a default in [brackets] — just press Enter to accept it.
EOF

  section "Admin user"
  ask ADMIN_USER "Admin username" valid_user "The account you'll log in with (root login will be disabled)."

  section "SSH keys for $ADMIN_USER"
  existing_keys=0
  if id "$ADMIN_USER" &>/dev/null; then
    existing_keys="$(count_keys "$(getent passwd "$ADMIN_USER" | cut -d: -f6)/.ssh/authorized_keys")"
    existing_keys="${existing_keys:-0}"
    (( existing_keys > 0 )) && echo "    $ADMIN_USER already has $existing_keys key(s) installed." || true
  fi

  # 1) Check root's keys (usually put there by the VPS provider)
  if (( ROOT_KEY_COUNT > 0 )); then
    echo "    Found $ROOT_KEY_COUNT key(s) in /root/.ssh/authorized_keys:"
    for k in "${ROOT_KEYS[@]}"; do echo "      $(key_fingerprint "$k")"; done
    ask_yn COPY_ROOT_KEYS "Copy these to $ADMIN_USER?"
  else
    echo "    No keys found on root."
    COPY_ROOT_KEYS=no
  fi

  # 2) Paste more keys; 3) if there's still no key, confirm or go back
  [[ -n "$ADMIN_SSH_KEY" ]] && echo "    $(grep -c . <<< "$ADMIN_SSH_KEY") key(s) already given via --ssh-key." || true
  while true; do
    echo "    ${C_DIM}Paste a public key (contents of ~/.ssh/id_ed25519.pub on YOUR computer), or Enter to skip.${C_RESET}"
    echo "    ${C_DIM}No key yet? On your computer run: ssh-keygen -t ed25519${C_RESET}"
    while true; do
      read -r -p "  ${C_BOLD}Public key${C_RESET} [none]: " k < /dev/tty || k=""
      [[ -z "$k" ]] && break
      if ! valid_sshkey "$k"; then
        echo "    ${C_RED}Not a valid public key (should start with ssh-ed25519, ssh-rsa, ...).${C_RESET}"
        continue
      fi
      ADMIN_SSH_KEY+="${ADMIN_SSH_KEY:+$'\n'}$k"
      echo "    ${C_GREEN}✔ added: $(key_fingerprint "$k")${C_RESET}"
      another=no
      ask_yn another "Add another key?"
      [[ "$another" == "yes" ]] || break
    done
    if [[ -n "$ADMIN_SSH_KEY" || "$COPY_ROOT_KEYS" == "yes" ]] || (( existing_keys > 0 )); then
      break
    fi
    echo "    ${C_YELLOW}⚠ $ADMIN_USER has no SSH key. Password login will stay ON so you don't get locked out.${C_RESET}"
    continue_nokey=yes
    ask_yn continue_nokey "Continue without a key? (n = go back and paste one)"
    [[ "$continue_nokey" == "yes" ]] && break
  done
  if [[ -n "$ADMIN_SSH_KEY" || "$COPY_ROOT_KEYS" == "yes" ]] || (( existing_keys > 0 )); then
    WIZ_HAS_KEY=yes
  else
    WIZ_HAS_KEY=no
  fi

  section "sudo"
  if [[ "$WIZ_HAS_KEY" == "yes" ]]; then
    [[ "$ADMIN_SUDO_NOPASSWD" == "auto" ]] && ADMIN_SUDO_NOPASSWD=yes || true
    ask_yn ADMIN_SUDO_NOPASSWD "Passwordless sudo for $ADMIN_USER?"
  else
    echo "    No SSH key, so $ADMIN_USER logs in with a password — sudo will use that password too."
    ADMIN_SUDO_NOPASSWD=no
  fi
  if [[ "$ADMIN_SUDO_NOPASSWD" == "no" && -z "$ADMIN_PASSWORD" ]]; then
    has_pw=no
    passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}' | grep -q '^P' && has_pw=yes || true
    pw_default="auto-generate"; [[ "$has_pw" == "yes" ]] && pw_default="keep current"
    while true; do
      read -r -s -p "  ${C_BOLD}Password for $ADMIN_USER${C_RESET} [$pw_default]: " p1 < /dev/tty || p1=""; echo > /dev/tty
      if [[ -z "$p1" ]]; then
        [[ "$has_pw" == "yes" ]] || GENERATE_PASSWORD=yes
        break
      fi
      if (( ${#p1} < 8 )); then echo "    ${C_RED}Use at least 8 characters (or press Enter for the default).${C_RESET}"; continue; fi
      read -r -s -p "  ${C_BOLD}Repeat password${C_RESET}: " p2 < /dev/tty || p2=""; echo > /dev/tty
      if [[ "$p1" != "$p2" ]]; then echo "    ${C_RED}Passwords don't match.${C_RESET}"; continue; fi
      ADMIN_PASSWORD="$p1"; break
    done
    unset p1 p2
  fi

  section "SSH"
  ask SSH_PORT "SSH port" valid_port "$([[ "$SSH_PORT_RANDOM" == yes ]] && echo "Picked at random for this server; keep it or type your own. " || true)Open it in your provider's firewall, if it has one, before you log in on it."
  ask SSH_ALLOW_TCP_FORWARDING "TCP forwarding (no/local/yes)" valid_forwarding "'local' lets you tunnel to e.g. a database with ssh -L."

  section "Firewall"
  ask FIREWALL_TCP_PORTS "Public TCP ports" valid_ports "Space-separated; SSH is added automatically."
  ask FIREWALL_UDP_PORTS "Public UDP ports" valid_ports "443 enables HTTP/3. Type none for no UDP ports."

  section "System"
  [[ -z "$SET_HOSTNAME" ]] && SET_HOSTNAME="$CURRENT_HOSTNAME" || true
  ask SET_HOSTNAME "Hostname" valid_hostname "e.g. web01.example.com"
  [[ -z "$TIMEZONE" ]] && TIMEZONE="$CURRENT_TZ" || true
  ask TIMEZONE "Timezone" valid_timezone "e.g. UTC, Europe/London, Asia/Singapore"
  ask SWAP_SIZE "Swap size (auto/none/2G)" valid_swap "auto = same as RAM, between 1G and 4G. Skipped if swap already exists."

  section "Updates"
  ask_yn AUTO_REBOOT "Reboot automatically when security updates need it?"
  if [[ "$AUTO_REBOOT" == "yes" ]]; then
    ask AUTO_REBOOT_TIME "Reboot time (HH:MM, server time)" valid_time
  fi

  section "Extras"
  ask_yn INSTALL_DOCKER "Install Docker + Docker Compose?"
fi

# Values equal to the current state mean "leave unchanged"
[[ "$SET_HOSTNAME" == "$CURRENT_HOSTNAME" ]] && SET_HOSTNAME="" || true
[[ "$TIMEZONE" == "$CURRENT_TZ" ]] && TIMEZONE="" || true

# ----------------------------- Validate --------------------------------------
TIMEZONE="$(none_to_empty "$TIMEZONE")"
SET_HOSTNAME="$(none_to_empty "$SET_HOSTNAME")"
FIREWALL_TCP_PORTS="$(none_to_empty "$FIREWALL_TCP_PORTS")"
FIREWALL_UDP_PORTS="$(none_to_empty "$FIREWALL_UDP_PORTS")"
for v in COPY_ROOT_KEYS AUTO_REBOOT INSTALL_DOCKER; do printf -v "$v" '%s' "$(yesno "${!v}")"; done
[[ "$ADMIN_SUDO_NOPASSWD" == "auto" ]] || ADMIN_SUDO_NOPASSWD="$(yesno "$ADMIN_SUDO_NOPASSWD")"

valid_user "$ADMIN_USER"                      || die "Invalid admin user: $ADMIN_USER"
valid_port "$SSH_PORT"                        || die "Invalid SSH port: $SSH_PORT"
valid_forwarding "$SSH_ALLOW_TCP_FORWARDING"  || die "Invalid forwarding mode: $SSH_ALLOW_TCP_FORWARDING"
valid_ports "$FIREWALL_TCP_PORTS"             || die "Invalid TCP ports: $FIREWALL_TCP_PORTS"
valid_ports "$FIREWALL_UDP_PORTS"             || die "Invalid UDP ports: $FIREWALL_UDP_PORTS"
valid_hostname "$SET_HOSTNAME"                || die "Invalid hostname: $SET_HOSTNAME"
valid_timezone "$TIMEZONE"                    || die "Unknown timezone: $TIMEZONE"
valid_swap "$SWAP_SIZE"                       || die "Invalid swap size: $SWAP_SIZE"
valid_time "$AUTO_REBOOT_TIME"                || die "Invalid reboot time: $AUTO_REBOOT_TIME"
valid_password "$ADMIN_PASSWORD"              || die "Passwords must not contain line breaks"
[[ "$ADMIN_SUDO_NOPASSWD" =~ ^(yes|no|auto)$ ]] || die "Invalid ADMIN_SUDO_NOPASSWD: $ADMIN_SUDO_NOPASSWD"
for v in COPY_ROOT_KEYS AUTO_REBOOT INSTALL_DOCKER; do valid_yesno "${!v}" || die "$v must be yes or no"; done
while IFS= read -r k; do
  [[ -z "$k" ]] || valid_sshkey "$k" || die "Invalid SSH public key (value omitted)"
done <<< "$ADMIN_SSH_KEY"

SWAP_REQUESTED="$SWAP_SIZE"   # step 9 turns "auto" into a size; save what was asked for

# ----------------------------- Confirm ---------------------------------------
# Work out the final key situation so the summary shows real values, not "auto"
new_keys="$(grep -c . <<< "$ADMIN_SSH_KEY" || true)"
copied_keys=0; [[ "$COPY_ROOT_KEYS" == "yes" ]] && copied_keys=$ROOT_KEY_COUNT || true
user_keys=0
if id "$ADMIN_USER" &>/dev/null; then
  user_keys="$(count_keys "$(getent passwd "$ADMIN_USER" | cut -d: -f6)/.ssh/authorized_keys")"
fi
parts=()
(( ${new_keys:-0} > 0 ))  && parts+=("$new_keys new") || true
(( copied_keys > 0 ))     && parts+=("$copied_keys from root") || true
(( ${user_keys:-0} > 0 )) && parts+=("$user_keys existing") || true
if (( ${#parts[@]} )); then
  key_summary="$(IFS=,; echo "${parts[*]}")"
  key_summary="${key_summary//,/, } → key-only login"
  [[ "$ADMIN_SUDO_NOPASSWD" == "auto" ]] && ADMIN_SUDO_NOPASSWD=yes || true
else
  key_summary="none → password login stays ON"
  [[ "$ADMIN_SUDO_NOPASSWD" == "auto" ]] && ADMIN_SUDO_NOPASSWD=no || true
fi
cat <<EOF

${C_BLUE}serverbeef — about to configure this server:${C_RESET}
  Admin user ............ $ADMIN_USER
  SSH keys .............. $key_summary
  Passwordless sudo ..... $ADMIN_SUDO_NOPASSWD$([[ "$GENERATE_PASSWORD" == yes ]] && echo " (password: auto-generated, delivered privately before the account update)")
  SSH port .............. $SSH_PORT (forwarding: $SSH_ALLOW_TCP_FORWARDING)$([[ "$SSH_PORT_RANDOM" == yes ]] && echo " ${C_YELLOW}picked at random: write it down and open it in your provider's firewall${C_RESET}")
  Public TCP ports ...... ${FIREWALL_TCP_PORTS:-none}
  Public UDP ports ...... ${FIREWALL_UDP_PORTS:-none}
  Hostname .............. ${SET_HOSTNAME:-(unchanged)}
  Timezone .............. ${TIMEZONE:-(unchanged)}
  Swap .................. $SWAP_SIZE
  Auto reboot ........... $AUTO_REBOOT$([[ "$AUTO_REBOOT" == yes ]] && echo " ($AUTO_REBOOT_TIME)")
  Install Docker ........ $INSTALL_DOCKER

EOF
if [[ "$INTERACTIVE" == "yes" ]]; then
  read -r -p "${C_BOLD}Apply these settings?${C_RESET} [Y/n]: " reply < /dev/tty || reply=""
  [[ "$(yesno "${reply:-yes}")" == "yes" ]] || { echo "Aborted — nothing was changed."; exit 1; }
elif [[ "$ASSUME_YES" != "yes" ]]; then
  die "No terminal available for the wizard. Re-run with --yes to use the values given by flags/env."
fi

# The log holds no secrets (passwords go to /dev/tty), but keep it root-only.
[[ -e "$LOG_FILE" ]] || (umask 077; : > "$LOG_FILE")
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== serverbeef run started $(date -Is) ==="

# ============================================================================
step "1/11 Updating system and installing base packages"
# ============================================================================
apt-get update -q
apt-get "${APT_OPTS[@]}" full-upgrade
apt-get "${APT_OPTS[@]}" install \
  ca-certificates curl wget gnupg git unzip zip jq rsync openssh-server sudo \
  htop btop ncdu tmux vim less bash-completion dnsutils net-tools \
  ufw fail2ban python3-systemd \
  unattended-upgrades apt-listchanges needrestart \
  apparmor apparmor-utils chrony logrotate lynis
apt-get "${APT_OPTS[@]}" autoremove --purge
ok "System up to date"

# needrestart: restart services automatically instead of prompting
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/50-${MARK}.conf <<'EOF'
$nrconf{restart} = 'a';
$nrconf{kernelhints} = 0;
EOF

# ============================================================================
step "2/11 Hostname and timezone"
# ============================================================================
if [[ -n "$SET_HOSTNAME" ]]; then
  hostnamectl set-hostname "$SET_HOSTNAME"
  short="${SET_HOSTNAME%%.*}"
  if ! grep -qE "^127\.0\.1\.1\s" /etc/hosts; then
    echo "127.0.1.1 $SET_HOSTNAME $short" >> /etc/hosts
  else
    sed -i -E "s/^127\.0\.1\.1\s.*/127.0.1.1 $SET_HOSTNAME $short/" /etc/hosts
  fi
  ok "Hostname set to $SET_HOSTNAME"
fi
if [[ -n "$TIMEZONE" ]]; then
  timedatectl set-timezone "$TIMEZONE"
  ok "Timezone set to $TIMEZONE"
fi
systemctl enable --now chrony >/dev/null 2>&1 || true
timedatectl set-ntp true 2>/dev/null || true
ok "Time sync enabled (chrony)"

# ============================================================================
step "3/11 Admin user '$ADMIN_USER'"
# ============================================================================
NEW_USER=no
if id "$ADMIN_USER" &>/dev/null; then
  ok "User exists"
else
  adduser --disabled-password --gecos "" "$ADMIN_USER" >/dev/null
  NEW_USER=yes
  ok "User created"
fi
ADMIN_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
AUTH_KEYS="$ADMIN_HOME/.ssh/authorized_keys"
# The home directory is user-controlled. Perform writes as that user so a
# symlink swap cannot make this root process overwrite or chown a system file.
# shellcheck disable=SC2016 # This program is interpreted by the child shell.
runuser -u "$ADMIN_USER" -- bash -c '
  set -e
  umask 077
  [[ ! -L "$1/.ssh" && ! -L "$2" ]]
  mkdir -p -- "$1/.ssh"
  chmod 700 -- "$1/.ssh"
  [[ ! -e "$2" || ( -f "$2" && $(stat -c %h -- "$2") == 1 ) ]]
  touch -- "$2"
  chmod 600 -- "$2"
' serverbeef "$ADMIN_HOME" "$AUTH_KEYS"

add_key() {
  local key="$1"
  [[ -z "$key" || "$key" =~ ^# ]] && return 0
  # shellcheck disable=SC2016 # This program is interpreted by the child shell.
  printf '%s\n' "$key" | runuser -u "$ADMIN_USER" -- bash -c '
    set -e
    IFS= read -r key
    [[ -f "$1" && ! -L "$1" && $(stat -c %h -- "$1") == 1 ]]
    if ! grep -qxF -- "$key" "$1"; then
      # A preceding key may lack a final newline.
      [[ ! -s "$1" || -z "$(tail -c 1 -- "$1")" ]] || printf "\n" >> "$1"
      printf "%s\n" "$key" >> "$1"
    fi
  ' serverbeef "$AUTH_KEYS"
}
if [[ -n "$ADMIN_SSH_KEY" ]]; then
  while IFS= read -r k; do add_key "$k"; done <<< "$ADMIN_SSH_KEY"
fi
if [[ "$COPY_ROOT_KEYS" == "yes" ]]; then
  # Copy only unrestricted validated keys; never remove provider restrictions.
  for k in "${ROOT_KEYS[@]}"; do add_key "$k"; done
fi
KEY_COUNT="$(count_keys "$AUTH_KEYS")"
if (( KEY_COUNT > 0 )); then
  ok "$KEY_COUNT SSH key(s) installed for $ADMIN_USER"
  HAVE_KEYS=yes
else
  warn "No SSH key for $ADMIN_USER — password login is still ON. Add a key and re-run this script to switch to key-only login."
  HAVE_KEYS=no
fi

# sudo / password. A user without an SSH key must have a password to log in,
# and a user without passwordless sudo needs one for sudo — generate if missing.
if [[ "$ADMIN_SUDO_NOPASSWD" == "auto" ]]; then
  [[ "$HAVE_KEYS" == "yes" ]] && ADMIN_SUDO_NOPASSWD=yes || ADMIN_SUDO_NOPASSWD=no
fi
HAS_PASSWORD=no
passwd -S "$ADMIN_USER" 2>/dev/null | awk '{print $2}' | grep -q '^P' && HAS_PASSWORD=yes || true
if [[ -z "$ADMIN_PASSWORD" && "$HAS_PASSWORD" == "no" ]] \
   && [[ "$GENERATE_PASSWORD" == "yes" || "$HAVE_KEYS" == "no" || "$ADMIN_SUDO_NOPASSWD" == "no" ]]; then
  ADMIN_PASSWORD="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  [[ ${#ADMIN_PASSWORD} -eq 48 ]] || die "Password generation failed"
  GENERATED_PASSWORD="$ADMIN_PASSWORD"
  # shellcheck disable=SC2119
  deliver_generated_password
fi
if [[ -n "$ADMIN_PASSWORD" ]]; then
  printf '%s:%s\n' "$ADMIN_USER" "$ADMIN_PASSWORD" | chpasswd
  ok "Password set for $ADMIN_USER${GENERATED_PASSWORD:+ (generated — delivered privately)}"
fi
unset ADMIN_PASSWORD GENERATED_PASSWORD
SUDOERS_FILE="/etc/sudoers.d/90-${MARK}-${ADMIN_USER}"
if [[ "$ADMIN_SUDO_NOPASSWD" == "yes" ]]; then
  SUDOERS_TEMP="$(mktemp "/etc/sudoers.d/${MARK}-sudoers.XXXXXX")"
  printf '# Managed by serverbeef.sh\n%s ALL=(ALL:ALL) NOPASSWD:ALL\n' "$ADMIN_USER" > "$SUDOERS_TEMP"
  chmod 440 "$SUDOERS_TEMP"
  if ! visudo -cf "$SUDOERS_TEMP" >/dev/null; then
    mv "$SUDOERS_TEMP" "$SUDOERS_TEMP.broken"; die "sudoers validation failed; previous policy preserved"
  fi
  mv -fT "$SUDOERS_TEMP" "$SUDOERS_FILE"
  # sudo-rs validates ALL matching entries for sudo -v. Combining a NOPASSWD
  # user rule with Ubuntu's password-required %sudo rule still prompts. Grant
  # this admin sudo directly and use ssh-users for SSH; keep other sudo users'
  # authentication requirements intact.
  getent group ssh-users >/dev/null || groupadd ssh-users
  usermod -aG ssh-users "$ADMIN_USER"
  if id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx sudo; then
    gpasswd -d "$ADMIN_USER" sudo >/dev/null
  fi
  if ! runuser -u "$ADMIN_USER" -- sudo -n -v || ! runuser -u "$ADMIN_USER" -- sudo -n true; then
    die "Passwordless sudo conflicts with another policy. Review sudo -l -U $ADMIN_USER before changing SSH."
  fi
  ok "Passwordless sudo for $ADMIN_USER"
  [[ "$NEW_USER" == "yes" ]] && warn "$ADMIN_USER has passwordless sudo; protect that SSH key"
else
  usermod -aG sudo "$ADMIN_USER"
  rm -f "$SUDOERS_FILE"
  ok "sudo requires $ADMIN_USER's password"
fi

# ============================================================================
step "4/11 Hardening SSH"
# ============================================================================
# sshd uses the FIRST value it sees, and sshd_config.d/*.conf is included at the
# top of sshd_config, so a "00-" file overrides cloud-init's 50-cloud-init.conf.
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-${MARK}.conf"
SSHD_PREVIOUS_PORTS="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')" \
  || die "Cannot read the existing SSH policy; repair it before setup"
SSHD_BACKUP=""
if [[ -e "$SSHD_DROPIN" ]]; then
  SSHD_BACKUP="$(mktemp "/etc/ssh/sshd_config.d/${MARK}-previous.XXXXXX")"
  cp -p "$SSHD_DROPIN" "$SSHD_BACKUP"
fi
SSHD_TEMP="$(mktemp "/etc/ssh/sshd_config.d/${MARK}-candidate.XXXXXX")"
restore_sshd_dropin() {
  mv -fT "$SSHD_DROPIN" "$SSHD_DROPIN.broken"
  if [[ -n "$SSHD_BACKUP" ]]; then mv -fT "$SSHD_BACKUP" "$SSHD_DROPIN"; fi
}
if [[ "$HAVE_KEYS" == "yes" ]]; then
  AUTH_BLOCK="PermitRootLogin no
PasswordAuthentication no
AuthenticationMethods publickey
AllowGroups sudo ssh-users"
  AUTH_DESC="key-only, root login disabled"
else
  # Without a key the admin logs in with their password, so keep that on.
  # Root keeps key-only login as an escape hatch; root passwords are refused.
  AUTH_BLOCK="PermitRootLogin prohibit-password
PasswordAuthentication yes"
  AUTH_DESC="password login ON for $ADMIN_USER (no key), root password login off"
fi
cat > "$SSHD_TEMP" <<EOF
# Managed by serverbeef.sh
Port $SSH_PORT
$AUTH_BLOCK
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no

MaxAuthTries 3
MaxSessions 10
MaxStartups 10:30:60
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding $SSH_ALLOW_TCP_FORWARDING
AllowStreamLocalForwarding no
GatewayPorts no
PermitTunnel no
PermitUserEnvironment no

UseDNS no
LogLevel VERBOSE
PrintMotd no
EOF
chmod 644 "$SSHD_TEMP"
# Group for non-sudo users you may want to allow SSH later (e.g. a CI deploy user):
#   usermod -aG ssh-users <name>
getent group ssh-users >/dev/null || groupadd ssh-users

# Ensure the Include line exists (it does on stock Ubuntu)
grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config

mkdir -p /run/sshd
mv -fT "$SSHD_TEMP" "$SSHD_DROPIN"
if ! sshd -t || ! ssh_policy_ok; then
  restore_sshd_dropin
  die "SSH syntax or effective policy check failed — candidate moved to $SSHD_DROPIN.broken; previous drop-in restored. Review other SSH files and Match rules."
fi
ok "sshd config valid ($AUTH_DESC)"
# Keep the previous on-disk SSH configuration until the firewall is ready.
# An interrupted firewall step must not leave a new SSH port active on reboot.
mv -fT "$SSHD_DROPIN" "$SSHD_TEMP"
if [[ -n "$SSHD_BACKUP" ]]; then cp -p "$SSHD_BACKUP" "$SSHD_DROPIN"; fi
# SSH is restarted after the firewall allows the new port (step 5).

# ============================================================================
step "5/11 Firewall (UFW)"
# ============================================================================
# Apply the firewall to both address families, including an existing IPv6 VPS.
sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
grep -qx 'IPV6=yes' /etc/default/ufw || die "Could not enable UFW IPv6 protection"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw default deny routed >/dev/null
ufw limit "$SSH_PORT/tcp" comment "SSH" >/dev/null
for p in $FIREWALL_TCP_PORTS; do ufw allow "$p/tcp" comment "public" >/dev/null; done
for p in $FIREWALL_UDP_PORTS; do ufw allow "$p/udp" comment "public" >/dev/null; done
ufw logging low >/dev/null
ufw --force enable >/dev/null
ok "UFW enabled: SSH($SSH_PORT/tcp, rate-limited) ${FIREWALL_TCP_PORTS:+tcp:[$FIREWALL_TCP_PORTS] }${FIREWALL_UDP_PORTS:+udp:[$FIREWALL_UDP_PORTS]}"
if [[ "$SSH_PORT" != "22" ]]; then
  # Rules for port 22 may predate this script (e.g. a provider's "allow 22/tcp"
  # or "allow OpenSSH"); build the exact delete command for each one.
  while IFS= read -r rule; do
    rule="${rule%% comment *}"
    warn "Port 22 is still open in UFW. After confirming SSH works on port $SSH_PORT, run: ${rule/#ufw /ufw delete }"
  done < <(ufw show added 2>/dev/null | grep -E "^ufw (allow|limit)( in)? (22|22/tcp|OpenSSH)( |$)" || true)
fi

# Now apply SSH config. Ubuntu uses socket activation (ssh.socket), whose
# listening port is generated from sshd_config — hence daemon-reload.
mv -fT "$SSHD_TEMP" "$SSHD_DROPIN"
systemctl daemon-reload
restart_ssh() {
  if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    systemctl restart ssh.socket ssh.service
  else
    systemctl restart ssh.service
  fi
}
if restart_ssh && sleep 1 && ss -tlnpH | grep -E '("sshd"|"systemd")' | awk '{print $4}' | grep -qE "[:.]${SSH_PORT}$"; then
  ok "SSH listening on port $SSH_PORT"
else
  restore_sshd_dropin
  # A fresh UFW setup may have blocked the previous SSH port. Reopen it before
  # activating the restored policy, retaining the new rule for recovery too.
  for p in $SSHD_PREVIOUS_PORTS; do
    if valid_port "$p"; then ufw limit "$p/tcp" comment "SSH rollback" >/dev/null || true; fi
  done
  systemctl daemon-reload
  restart_ssh || true
  die "SSH activation failed; previous drop-in restored. Keep this session open and check SSH and firewall access."
fi
[[ -z "$SSHD_BACKUP" ]] || rm -f "$SSHD_BACKUP"

# ============================================================================
step "6/11 Fail2ban"
# ============================================================================
cat > /etc/fail2ban/jail.d/${MARK}.local <<EOF
# Managed by serverbeef.sh
[DEFAULT]
backend            = systemd
banaction          = nftables-multiport
banaction_allports = nftables-allports
bantime            = 1h
bantime.increment  = true
bantime.maxtime    = 1w
findtime           = 10m
maxretry           = 5
ignoreip           = 127.0.0.1/8 ::1

[sshd]
enabled  = true
port     = $SSH_PORT
mode     = aggressive
maxretry = 4

[recidive]
enabled  = true
backend  = auto
logpath  = /var/log/fail2ban.log
bantime  = 1w
findtime = 1d
maxretry = 3
EOF
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban
sleep 2
if fail2ban-client status sshd >/dev/null 2>&1 && fail2ban-client status recidive >/dev/null 2>&1; then
  ok "Fail2ban active (sshd + recidive jails)"
else warn "Fail2ban did not start cleanly — check: journalctl -u fail2ban"
fi

# ============================================================================
step "7/11 Automatic security updates"
# ============================================================================
cat > /etc/apt/apt.conf.d/90${MARK}-periodic <<'EOF'
// Managed by serverbeef.sh
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52${MARK}-unattended-upgrades <<EOF
// Managed by serverbeef.sh (overrides 50unattended-upgrades)
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "$( [[ "$AUTO_REBOOT" == "yes" ]] && echo true || echo false )";
Unattended-Upgrade::Automatic-Reboot-WithUsers "true";
Unattended-Upgrade::Automatic-Reboot-Time "$AUTO_REBOOT_TIME";
Unattended-Upgrade::SyslogEnable "true";
EOF
systemctl enable --now unattended-upgrades >/dev/null 2>&1
ok "Unattended security upgrades enabled (auto-reboot: $AUTO_REBOOT @ $AUTO_REBOOT_TIME)"

# ============================================================================
step "8/11 Kernel hardening + network performance tuning"
# ============================================================================
modprobe tcp_bbr 2>/dev/null || true
printf '# Managed by serverbeef.sh\ntcp_bbr\n' > /etc/modules-load.d/${MARK}-bbr.conf

cat > /etc/sysctl.d/90-${MARK}.conf <<'EOF'
# Managed by serverbeef.sh

### ---- Network performance ----
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

### ---- Network hardening ----
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

### ---- Kernel hardening ----
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.sysrq = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0

### ---- Resources ----
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
sysctl --system >/dev/null 2>&1 || warn "Some sysctl keys were rejected (often harmless in containers) — check: sysctl --system"
ok "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"

# ============================================================================
step "9/11 Swap, limits, journald"
# ============================================================================
if [[ "$SWAP_SIZE" != "none" ]] && [[ -z "$(swapon --show --noheadings)" ]]; then
  if [[ "$SWAP_SIZE" == "auto" ]]; then
    ram_mb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
    swap_mb=$ram_mb
    (( swap_mb < 1024 )) && swap_mb=1024
    (( swap_mb > 4096 )) && swap_mb=4096
    SWAP_SIZE="${swap_mb}M"
  fi
  root_fs="$(findmnt -no FSTYPE /)"
  if [[ "$root_fs" == "btrfs" ]]; then
    btrfs filesystem mkswapfile --size "$SWAP_SIZE" /swapfile >/dev/null
  else
    (umask 077; fallocate -l "$SWAP_SIZE" /swapfile 2>/dev/null \
      || dd if=/dev/zero of=/swapfile bs=1M count="$(numfmt --from=iec "$SWAP_SIZE" | awk '{print int($1/1048576)}')" status=none)
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  ok "Swap file of $SWAP_SIZE created"
elif [[ "$SWAP_SIZE" == "none" ]]; then
  ok "Swap skipped (SWAP_SIZE=none)"
else
  ok "Swap already present: $(swapon --show --noheadings | awk '{print $1" "$3}' | head -1)"
fi

cat > /etc/security/limits.d/90-${MARK}.conf <<'EOF'
# Managed by serverbeef.sh
*    soft nofile 65535
*    hard nofile 1048576
root soft nofile 65535
root hard nofile 1048576
*    hard core   0
EOF
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/90-${MARK}.conf <<'EOF'
# Managed by serverbeef.sh
[Manager]
DefaultLimitNOFILE=65535:1048576
EOF

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-${MARK}.conf <<'EOF'
# Managed by serverbeef.sh
[Journal]
Storage=persistent
Compress=yes
SystemMaxUse=1G
SystemMaxFileSize=100M
MaxRetentionSec=1month
EOF
systemctl restart systemd-journald
systemctl daemon-reexec
ok "File limits raised, journald capped at 1G"

# ============================================================================
step "10/11 Misc hardening"
# ============================================================================
# No core dumps (can leak secrets from app memory)
mkdir -p /etc/systemd/coredump.conf.d
printf '# Managed by serverbeef.sh\n[Coredump]\nStorage=none\nProcessSizeMax=0\n' > /etc/systemd/coredump.conf.d/90-${MARK}.conf

# AppArmor on
systemctl enable --now apparmor >/dev/null 2>&1 || true
if aa-status --enabled 2>/dev/null; then ok "AppArmor enabled"
else warn "AppArmor is not enabled (normal in some containers)"
fi

# Don't let Ctrl-Alt-Del from a provider console reboot the box
systemctl mask ctrl-alt-del.target >/dev/null 2>&1 || true

# Private home directories
chmod 750 /home/* 2>/dev/null || true
sed -i -E 's/^#?\s*DIR_MODE=.*/DIR_MODE=0750/' /etc/adduser.conf 2>/dev/null || true
sed -i -E 's/^#?\s*HOME_MODE\s+.*/HOME_MODE\t0750/' /etc/login.defs 2>/dev/null || true

# Only sudo-group members can use su
if ! grep -qE '^auth\s+required\s+pam_wheel\.so' /etc/pam.d/su; then
  sed -i -E 's/^#\s*(auth\s+required\s+pam_wheel\.so)\s*$/\1 group=sudo/' /etc/pam.d/su
fi

# Disable rarely-needed network protocols & filesystems
cat > /etc/modprobe.d/90-${MARK}-blacklist.conf <<'EOF'
# Managed by serverbeef.sh
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false
install cramfs /bin/false
install freevxfs /bin/false
install hfs /bin/false
install hfsplus /bin/false
install jffs2 /bin/false
EOF
ok "Core dumps off, su restricted, unused kernel modules blocked"

# ============================================================================
step "11/11 Optional: Docker"
# ============================================================================
if [[ "$INSTALL_DOCKER" == "yes" ]]; then
  apt-get "${APT_OPTS[@]}" install docker.io docker-compose-v2 docker-buildx
  mkdir -p /etc/docker
  if [[ ! -f /etc/docker/daemon.json ]]; then
    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "local",
  "log-opts": { "max-size": "20m", "max-file": "5" },
  "live-restore": true
}
EOF
  fi
  systemctl enable --now docker >/dev/null 2>&1
  systemctl restart docker
  usermod -aG docker "$ADMIN_USER"
  ok "Docker $(docker --version | awk '{print $3}' | tr -d ,) installed; $ADMIN_USER added to docker group"
  warn "Docker-published ports BYPASS UFW. Bind internal services to localhost, e.g. -p 127.0.0.1:5432:5432"
else
  ok "Skipped (set INSTALL_DOCKER=yes to install)"
fi

# ============================================================================
#  Save settings (marks this server as set up — used by re-runs and --verify)
# ============================================================================
install -d -m 700 "$STATE_DIR"
SWAP_SIZE="$SWAP_REQUESTED"
{
  echo "# Managed by serverbeef.sh. Used as defaults on re-run."
  echo "SB_LAST_RUN=\"$(date '+%Y-%m-%d %H:%M')\""
  for key in $STATE_KEYS; do echo "$key=\"${!key}\""; done
} > "$STATE_FILE"
chmod 600 "$STATE_FILE"
# Keep a copy so re-running is just: sudo serverbeef
if [[ -f "${BASH_SOURCE[0]}" ]]; then
  if [[ ! "${BASH_SOURCE[0]}" -ef /usr/local/sbin/serverbeef ]]; then
    install -m 755 "${BASH_SOURCE[0]}" /usr/local/sbin/serverbeef
  fi
  RERUN_CMD="sudo serverbeef"
else
  RERUN_CMD="sudo bash serverbeef.sh"
fi

# ============================================================================
#  Summary
# ============================================================================
IP="$(curl -fsS -4 --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo
echo "${C_GREEN}=============================================================${C_RESET}"
if [[ "$HAVE_KEYS" == yes ]]; then
  echo "${C_GREEN} serverbeef setup finished — verify the new login${C_RESET}  (log: $LOG_FILE)"
else
  echo "${C_YELLOW} serverbeef INCOMPLETE — no validated admin key${C_RESET}  (log: $LOG_FILE)"
fi
echo "${C_GREEN}=============================================================${C_RESET}"
cat <<EOF

 SSH now listens on port ${C_BOLD}$SSH_PORT${C_RESET}. Write it down, allow it in your provider's firewall if it has one,
 and add it to your ~/.ssh/config.

 ${C_YELLOW}BEFORE closing this session${C_RESET}, open a NEW terminal and test:

     ssh -p $SSH_PORT $ADMIN_USER@$IP
     sudo -v

 Then, from that new session, verify everything (cleans up leftover
 firewall rules and runs a security audit):

     $RERUN_CMD --verify

 Useful commands:
     sudo ufw status verbose          # firewall rules
     sudo fail2ban-client status sshd # banned IPs
     sudo unattended-upgrade --dry-run --debug

 Add a public port later:  sudo ufw allow 8080/tcp
EOF
if (( ${#WARNINGS[@]} )); then
  echo
  echo "${C_YELLOW} Warnings:${C_RESET}"
  for w in "${WARNINGS[@]}"; do echo "   - $w"; done
fi
if [[ -f /var/run/reboot-required ]]; then
  echo
  echo "${C_YELLOW} A reboot is required to finish applying updates: sudo reboot${C_RESET}"
fi
echo

[[ "$HAVE_KEYS" == yes ]] || exit 1
