#!/usr/bin/env bash
# serverbeef-local.sh: run this on YOUR computer first, once per server.
#
# It prepares everything the server setup needs from your side:
#   1. two SSH keys: an admin key for you (protected by a passphrase, it is the key that can become root) and a
#      deploy key for CI and AI agents (no passphrase; it never gets root),
#   2. two entries in ~/.ssh/config, <name> and <name>_deploy, so that `ssh <name>` just works afterwards,
#   3. a small config file with your answers (admin name, SSH port, both public keys), uploaded next to
#      serverbeef.sh so the setup on the server shows them as its defaults.
#
# Run it again for the same IP and it offers to reuse what exists (for example to add the missing deploy key)
# or to reset it after you reinstalled the server. Private keys never leave this computer.
#
#   bash serverbeef-local.sh            # asks: server IP, friendly name, admin name, SSH port, passphrase
set -Eeuo pipefail

SSH_DIR="$HOME/.ssh"
SSH_CONFIG="$SSH_DIR/config"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVERBEEF="$SCRIPT_DIR/serverbeef.sh"
STAMP="$(date +%Y%m%d%H%M%S)"

if [[ -t 1 ]]; then B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'; else B='' G='' Y='' R='' D='' N=''; fi
ok()   { printf '%s  ✔%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s  ⚠ %s%s\n' "$Y" "$*" "$N" >&2; }
die()  { printf '%s  ✖ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
section() { printf '\n%s── %s%s\n' "$B" "$*" "$N"; }

# ask VAR "Question" DEFAULT VALIDATOR [hint]
ask() {
  local __var="$1" __q="$2" __def="$3" __check="$4" __hint="${5:-}" __ans
  while true; do
    [[ -n "$__hint" ]] && printf '    %s%s%s\n' "$D" "$__hint" "$N"
    read -r -p "  ${B}${__q}${N} [${__def:-none}]: " __ans < /dev/tty || { echo; die "no answer, nothing changed"; }
    __ans="${__ans:-$__def}"
    if "$__check" "$__ans"; then printf -v "$__var" '%s' "$__ans"; return 0; fi
    printf '    %sInvalid value, try again.%s\n' "$R" "$N"; __hint=""
  done
}
# ask_yn VAR "Question?" yes|no
ask_yn() {
  local __var="$1" __q="$2" __def="$3" __ans
  while true; do
    read -r -p "  ${B}${__q}${N} [$([[ "$__def" == yes ]] && echo Y/n || echo y/N)]: " __ans < /dev/tty || { echo; die "no answer, nothing changed"; }
    case "${__ans:-$__def}" in y|Y|yes|YES) printf -v "$__var" yes; return ;; n|N|no|NO) printf -v "$__var" no; return ;; esac
  done
}

valid_ip()    { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]; }
valid_name()  { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ && "$1" != *_deploy ]]; }
valid_admin() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$1" != root && "$1" != deploy ]]; }
valid_port()  { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 >= 1025 && 10#$1 <= 65535 )); }
valid_role()  { [[ "$1" == admin || "$1" == deploy ]]; }
valid_login() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
valid_any_port() { [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
valid_mode()  { [[ "${1,,}" =~ ^(u|reuse|s|reset)$ ]]; }
always_ok()   { true; }
expand_tilde() { printf '%s' "${1/#\~/$HOME}"; }

# config_blocks_for FILE IP: every Host block of FILE whose HostName (or Host) is IP, one per line:
#   alias|user|port|identityfile   (empty fields when the block does not set them)
config_blocks_for() {
  [[ -f "$1" ]] || return 0
  awk -v ip="$2" '
    function flush() { if (alias != "" && (tolower(hn) == tolower(ip) || (hn == "" && alias == ip))) print alias "|" user "|" port "|" idf }
    tolower($1) == "host" || tolower($1) == "match" { flush(); alias = (tolower($1) == "host") ? $2 : ""; hn = ""; user = ""; port = ""; idf = ""; next }
    tolower($1) == "hostname"     { hn = $2 }
    tolower($1) == "user"         { user = $2 }
    tolower($1) == "port"         { port = $2 }
    tolower($1) == "identityfile" { if (idf == "") idf = $2 }
    END { flush() }
  ' "$1"
}
# remove_blocks_for FILE IP: FILE without those blocks (and the blank lines right before them), to stdout
remove_blocks_for() {
  [[ -f "$1" ]] || return 0
  awk -v ip="$2" '
    function flush() {
      if (n == 0) return
      drop = (alias != "" && (tolower(hn) == tolower(ip) || (hn == "" && alias == ip)))
      if (!drop) for (i = 1; i <= n; i++) print buf[i]
      n = 0
    }
    tolower($1) == "host" || tolower($1) == "match" { flush(); alias = (tolower($1) == "host") ? $2 : ""; hn = "" }
    tolower($1) == "hostname" { hn = $2 }
    { buf[++n] = $0 }
    END { flush() }
  ' "$1" | cat -s
}
# key_used_elsewhere FILE IP KEYFILE: is KEYFILE an IdentityFile of a block for another host?
key_used_elsewhere() {
  local idf
  while IFS= read -r idf; do
    [[ -n "$idf" && "$(expand_tilde "$idf")" == "$(expand_tilde "$3")" ]] && return 0
  done < <(awk -v ip="$2" '
    function flush() { if (alias != "" && !(tolower(hn) == tolower(ip) || (hn == "" && alias == ip))) for (i = 1; i <= k; i++) print idfs[i]; k = 0 }
    tolower($1) == "host" || tolower($1) == "match" { flush(); alias = (tolower($1) == "host") ? $2 : ""; hn = ""; next }
    tolower($1) == "hostname" { hn = $2 }
    tolower($1) == "identityfile" { idfs[++k] = $2 }
    END { flush() }
  ' "$1")
  return 1
}
write_block() {   # write_block ALIAS USER KEYFILE: appended after one blank line
  local gap=$'\n'
  [[ -s "$SSH_CONFIG" ]] || gap=""
  [[ "$(tail -c 2 "$SSH_CONFIG" 2>/dev/null | tr -c '\n' x)" == $'\n\n' ]] && gap=""
  printf '%sHost %s\n  HostName %s\n  Port %s\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n' "$gap" "$1" "$IP" "$PORT" "$2" "$3" >> "$SSH_CONFIG"
}
set_aside() {     # set_aside KEYFILE: move a key pair out of the way, remembered for the cleanup question
  local f; f="$(expand_tilde "$1")"
  [[ -e "$f" ]] || return 0
  mv -- "$f" "$f.replaced-$STAMP"; [[ -e "$f.pub" ]] && mv -- "$f.pub" "$f.pub.replaced-$STAMP"
  SET_ASIDE+=("$f.replaced-$STAMP")
}
make_key() {      # make_key NAME COMMENT PASSPHRASE: into the work dir; installed into ~/.ssh only after the confirmation
  ssh-keygen -q -t ed25519 -N "$3" -C "$2" -f "$WORK/$1"
  NEW_KEYS+=("$1")
}

# ---------------------------------------------------------------------------------------------------------------
[[ "${1:-}" == -h || "${1:-}" == --help ]] && { sed -n '2,15p' "$0"; exit 0; }
for c in ssh ssh-keygen scp awk; do command -v "$c" >/dev/null || die "missing command: $c"; done
[[ -f "$SERVERBEEF" ]] || die "serverbeef.sh not found next to this script ($SERVERBEEF)"
{ : < /dev/tty; } 2>/dev/null || die "needs a terminal"
mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"; touch "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"

cat <<EOF

${B}serverbeef-local: prepare your computer for a new server${N}
  Three short parts: (1) how to reach the server today, (2) what it should become (name, admin, port), (3) keys.
  It then makes two SSH keys and two ssh aliases, and uploads serverbeef.sh with your answers to the server.
  The admin key gets a passphrase: it is the key that can become root. The deploy key is for CI and AI agents and
  gets none: that account can never reach root. Private keys stay on this computer. Nothing on the server changes
  until you run serverbeef.sh there.
EOF

section "1. The server as it is now"
echo "    How to reach it today, before serverbeef runs."
ask IP "Server IP address" "" valid_ip "From your provider's dashboard."

declare -a SET_ASIDE=() BLOCKS=()
MODE=new
NAME='' ADMIN='' PORT='' ADMIN_KEY='' DEPLOY_KEY=''
admin_alias='' admin_user='' admin_port='' admin_idf='' deploy_alias='' deploy_idf='' deploy_port=''
mapfile -t BLOCKS < <(config_blocks_for "$SSH_CONFIG" "$IP")
if (( ${#BLOCKS[@]} > 0 )); then
  echo "    ~/.ssh/config already knows $IP:"
  for b in "${BLOCKS[@]}"; do
    IFS='|' read -r alias user port idf <<<"$b"
    printf '      ssh %-20s user %-12s port %-6s key %s%s\n' "$alias" "${user:-?}" "${port:-22}" "${idf:-none}" \
      "$([[ -n "$idf" && ! -f "$(expand_tilde "$idf")" ]] && echo " (missing!)")"
  done
  ask MODE "re[u]se them, or re[s]et because you reinstalled the server? (u/s)" u valid_mode \
    "u = reuse: keep what exists, make only what is missing.  s = reset: remove these entries, forget the old host key, make new keys."
  case "${MODE,,}" in u|reuse) MODE=reuse ;; *) MODE=reset ;; esac
fi
if [[ "$MODE" == reuse ]]; then
  # sort the entries into an admin one and a deploy one
  for b in "${BLOCKS[@]}"; do
    IFS='|' read -r alias user port idf <<<"$b"
    if [[ "$user" == deploy || "$alias" == *_deploy ]]; then deploy_alias=$alias; deploy_idf=$idf; deploy_port=$port
    else admin_alias=$alias; admin_user=$user; admin_port=$port; admin_idf=$idf; fi
  done
  if [[ -n "$admin_idf" && ! -f "$(expand_tilde "$admin_idf")" ]]; then die "the admin key $admin_idf is gone; choose reset"; fi
  if [[ -n "$deploy_idf" && ! -f "$(expand_tilde "$deploy_idf")" ]]; then die "the deploy key $deploy_idf is gone; choose reset"; fi
  if [[ -n "$admin_idf" && -z "$deploy_idf" ]]; then
    ask ROLE "Only one key exists ($admin_idf). Is it the admin key or the deploy key?" admin valid_role \
      "The other one is made now. admin: your key with a passphrase. deploy: the key your agents use, no passphrase."
    if [[ "$ROLE" == deploy ]]; then deploy_idf=$admin_idf; deploy_port=$admin_port; deploy_alias=$admin_alias; admin_idf=''; admin_alias=''; fi
  fi
  [[ -z "$deploy_idf" ]] || DEPLOY_KEY="$deploy_idf"
elif [[ "$MODE" == reset ]]; then
  echo "    At the end, after you confirm: these entries leave ~/.ssh/config (a backup is kept), the old host key of"
  echo "    $IP is forgotten, and keys no other entry uses are set aside, not deleted. Ctrl-C before that changes nothing."
fi
# how the upload and the setup command reach the box
NOW_USER='' NOW_PORT='' NOW_ALIAS=''
if [[ -n "$admin_alias" ]]; then
  NOW_ALIAS="$admin_alias"; ADMIN="$admin_user"; PORT="${admin_port:-22}"; ADMIN_KEY="$admin_idf"
  ok "reached as $ADMIN through ssh $NOW_ALIAS (port $PORT, key $ADMIN_KEY): the server is already set up"
else
  ask NOW_USER "User you log in with today" root valid_login \
    "root on most providers. Some images use ubuntu, debian or admin instead; then sudo is used on the box."
  ask NOW_PORT "SSH port today" 22 valid_any_port
fi

section "2. The server after serverbeef"
echo "    What you want it to be. The ssh aliases on this computer and the setup's defaults come from these."
if valid_name "${NAME:-${admin_alias:-${deploy_alias%_deploy}}}"; then NAME="${admin_alias:-${deploy_alias%_deploy}}"; ok "name: $NAME"
else ask NAME "Friendly name for this server" "" valid_name "Short, lowercase: it becomes the ssh alias (ssh <name>, ssh <name>_deploy)."; fi
if valid_admin "${ADMIN:-}"; then ok "admin: $ADMIN"
else ask ADMIN "Admin username on the server" "" valid_admin "Required. The account you log in with; root login gets disabled. Not root, not deploy."; fi
PORT="${PORT:-$deploy_port}"
if valid_port "${PORT:-}"; then ok "SSH port: $PORT"
else ask PORT "SSH port for this server" "$(shuf -i 1025-9999 -n 1)" valid_port "A port of its own per server. Allow it in your provider's firewall if you have one."; fi

WORK="$(mktemp -d)"; chmod 700 "$WORK"; trap 'rm -rf "$WORK"' EXIT
declare -a NEW_KEYS=()

section "3. Keys"
[[ -z "$ADMIN_KEY" ]] || ok "admin key kept: $ADMIN_KEY"
[[ -z "$DEPLOY_KEY" ]] || ok "deploy key kept: $DEPLOY_KEY"
if [[ -z "$ADMIN_KEY" ]]; then
  ADMIN_KEY="$SSH_DIR/${NAME}_admin"
  echo "    The admin key's passphrase: typed every time you log in as $ADMIN (or once per session with ssh-agent)."
  while true; do
    read -r -s -p "  ${B}Passphrase for the admin key${N}: " p1 < /dev/tty || { echo; die "no answer"; }; echo
    read -r -s -p "  ${B}Again${N}: " p2 < /dev/tty || { echo; die "no answer"; }; echo
    [[ -n "$p1" && "$p1" == "$p2" ]] && break
    printf '    %s%s%s\n' "$R" "$([[ -z "$p1" ]] && echo "A passphrase is required for the admin key." || echo "They differ, try again.")" "$N"
  done
  make_key "${NAME}_admin" "$ADMIN@$NAME" "$p1"; unset p1 p2
  ok "admin key made: $ADMIN_KEY (passphrase)"
fi
if [[ -z "$DEPLOY_KEY" ]]; then
  DEPLOY_KEY="$SSH_DIR/${NAME}_deploy"
  make_key "${NAME}_deploy" "deploy@$NAME" ""
  ok "deploy key made: $DEPLOY_KEY (no passphrase)"
fi
pub_of() { local f; f="$(expand_tilde "$1")"; if [[ -f "$WORK/$(basename "$f").pub" ]]; then cat "$WORK/$(basename "$f").pub"; else cat "$f.pub"; fi; }
ADMIN_PUB="$(pub_of "$ADMIN_KEY")"
DEPLOY_PUB="$(pub_of "$DEPLOY_KEY")"

section "About to change ~/.ssh"
if [[ "$MODE" == reset ]]; then
  echo "    remove ${#BLOCKS[@]} entr$([[ ${#BLOCKS[@]} == 1 ]] && echo y || echo ies) for $IP from ~/.ssh/config (backup kept), forget its old host key, set old keys aside"
fi
for k in "${NEW_KEYS[@]}"; do
  echo "    install $SSH_DIR/$k$([[ -e "$SSH_DIR/$k" ]] && echo " (the file there now is set aside)")"
done
for entry in "$NAME:$ADMIN" "${NAME}_deploy:deploy"; do
  IFS=: read -r alias user <<<"$entry"
  if [[ "$MODE" != reset ]] && grep -qE "^[[:space:]]*Host[[:space:]]+$alias([[:space:]]|$)" "$SSH_CONFIG"; then echo "    keep   ssh $alias"
  else echo "    add    ssh $alias  (user $user, port $PORT)"; fi
done
echo "    upload serverbeef.sh and serverbeef-$NAME.conf (public keys only) to the server"
ask_yn GO "Go ahead?" yes
[[ "$GO" == yes ]] || die "stopped; nothing changed"

if [[ "$MODE" == reset ]]; then
  cp -p "$SSH_CONFIG" "$SSH_CONFIG.serverbeef-bak-$STAMP"
  remove_blocks_for "$SSH_CONFIG" "$IP" > "$SSH_CONFIG.new-$STAMP"
  mv -- "$SSH_CONFIG.new-$STAMP" "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"
  ok "removed the entries for $IP from ~/.ssh/config (backup: config.serverbeef-bak-$STAMP)"
  ssh-keygen -R "$IP" >/dev/null 2>&1 || true
  for b in "${BLOCKS[@]}"; do
    IFS='|' read -r alias _ port idf <<<"$b"
    if [[ -n "$port" && "$port" != 22 ]]; then ssh-keygen -R "[$IP]:$port" >/dev/null 2>&1 || true; fi
    ssh-keygen -R "$alias" >/dev/null 2>&1 || true
    if [[ -n "$idf" ]] && ! key_used_elsewhere "$SSH_CONFIG" "$IP" "$idf"; then set_aside "$idf"; fi
  done
  ok "forgot the old host key of $IP (a reinstalled server has a new one)"
fi
for k in "${NEW_KEYS[@]}"; do
  set_aside "$SSH_DIR/$k"
  mv -- "$WORK/$k" "$SSH_DIR/$k"; mv -- "$WORK/$k.pub" "$SSH_DIR/$k.pub"
  chmod 600 "$SSH_DIR/$k"; chmod 644 "$SSH_DIR/$k.pub"
  ok "installed $SSH_DIR/$k"
done
(( ${#SET_ASIDE[@]} == 0 )) || ok "old keys set aside, not deleted: ${SET_ASIDE[*]}"

section "ssh aliases"
for entry in "$NAME:$ADMIN:$ADMIN_KEY" "${NAME}_deploy:deploy:$DEPLOY_KEY"; do
  IFS=: read -r alias user keyfile <<<"$entry"
  if grep -qE "^[[:space:]]*Host[[:space:]]+$alias([[:space:]]|$)" "$SSH_CONFIG"; then ok "ssh $alias (kept)"
  else write_block "$alias" "$user" "${keyfile/#$HOME/\~}"; ok "ssh $alias  (user $user, port $PORT)"; fi
done

section "Upload"
CONF="serverbeef-$NAME.conf"
cat > "$WORK/$CONF" <<EOF
# Made by serverbeef-local.sh on $(hostname) for $NAME ($IP). Public keys only.
ADMIN_USER=$ADMIN
SSH_PORT=$PORT
ADMIN_SSH_KEY="$ADMIN_PUB"
DEPLOY_SSH_KEY="$DEPLOY_PUB"
COPY_ROOT_KEYS=no
EOF
if [[ -n "$NOW_ALIAS" ]]; then
  scp_target=("$NOW_ALIAS:"); run_cmd="ssh -t $NOW_ALIAS 'sudo bash serverbeef.sh --config $CONF'"
  echo "    Uploading as $ADMIN through ssh $NOW_ALIAS."
else
  scp_target=(-P "$NOW_PORT" "$NOW_USER@$IP:")
  run_cmd="ssh -t -p $NOW_PORT $NOW_USER@$IP '$([[ "$NOW_USER" == root ]] || echo "sudo ")bash serverbeef.sh --config $CONF'"
  echo "    Uploading as $NOW_USER. A fresh server asks for $NOW_USER's password from your provider (or uses the key you"
  echo "    registered there). Type it once here; nothing is stored."
fi
if scp -o StrictHostKeyChecking=accept-new "$SERVERBEEF" "$WORK/$CONF" "${scp_target[@]}"; then
  ok "uploaded serverbeef.sh and $CONF"
else
  cp "$WORK/$CONF" "$SCRIPT_DIR/$CONF"
  warn "upload failed. The config file is kept at $SCRIPT_DIR/$CONF (public keys only). When the connection works, run:"
  warn "  scp ${scp_target[*]:0:${#scp_target[@]}-1} $SERVERBEEF $SCRIPT_DIR/$CONF ${scp_target[*]: -1}"
  echo "    Permission denied: wrong password, or that user only takes a key registered at the provider (ssh -i <that key>)."
  echo "    Connection reset: too many attempts in a row; wait a minute."
  trap - EXIT; rm -rf "$WORK"
fi

cat <<EOF

${B}Done on this computer.${N}

  Admin key  (you, passphrase):   $ADMIN_KEY
    $ADMIN_PUB
  Deploy key (CI and agents):     $DEPLOY_KEY
    $DEPLOY_PUB

${B}Next, on the server:${N}

    $run_cmd

  It shows your answers ($ADMIN, port $PORT, both keys) as defaults and asks about the rest. Keep that window open
  and, when it is done, test from a second terminal:  ssh $NAME   and   sudo -v
  Deployments then use:  ssh ${NAME}_deploy   (no sudo, no password)
EOF

if (( ${#SET_ASIDE[@]} > 0 )); then
  echo
  for f in "${SET_ASIDE[@]}"; do echo "    $f"; done
  ask_yn CLEAN "Delete these old key files? They are not referenced by ~/.ssh/config." no
  if [[ "$CLEAN" == yes ]]; then
    for f in "${SET_ASIDE[@]}"; do rm -f -- "$f" "${f/.replaced-/.pub.replaced-}"; done; ok "deleted"
  else echo "    kept; delete them yourself when you are sure."; fi
fi
