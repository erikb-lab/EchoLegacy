#!/usr/bin/env bash
set -euo pipefail

# Reverts /System/Library/CoreServices/SpringBoard.app/N72AP.plist from root-owned .bak and resprings.
LIK_BIN="/home/erik/Legacy-iOS-Kit/bin/linux/x86_64"
LIK_LIB="${LIK_BIN}/lib"
PORT="${IPROXY_PORT:-2235}"
KNOWN_HOSTS="${IPOD_KNOWN_HOSTS:-$HOME/.ssh/echolegacy_ipod_known_hosts}"

if [ -z "${IPOD_SSH_KEY:-}" ] && [ -z "${IPOD_PASS:-}" ]; then
  echo "[!] Error: Set IPOD_SSH_KEY or IPOD_PASS before running disable-multitasking.sh (no default 'alpine')." >&2
  exit 1
fi

mkdir -p "$(dirname "$KNOWN_HOSTS")"
chmod 700 "$(dirname "$KNOWN_HOSTS")" 2>/dev/null || true

LD_LIBRARY_PATH="$LIK_LIB" "$LIK_BIN/iproxy" "$PORT" 22 >/dev/null 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
sleep 1

SSH_OPTS=(
  -n
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
  -o ConnectTimeout=8
  -o KexAlgorithms=+diffie-hellman-group14-sha1
  -o HostKeyAlgorithms=+ssh-rsa
  -o PubkeyAcceptedAlgorithms=+ssh-rsa
)

if [ -n "${IPOD_SSH_KEY:-}" ]; then
  SSH_CMD=(env LD_LIBRARY_PATH="$LIK_LIB" "$LIK_BIN/ssh" "${SSH_OPTS[@]}" -o BatchMode=yes -i "$IPOD_SSH_KEY" -p "$PORT" root@127.0.0.1)
else
  export SSHPASS="$IPOD_PASS"
  SSH_CMD=(env LD_LIBRARY_PATH="$LIK_LIB" SSHPASS="$SSHPASS" "$LIK_BIN/sshpass" -e "$LIK_BIN/ssh" "${SSH_OPTS[@]}" -p "$PORT" root@127.0.0.1)
fi

"${SSH_CMD[@]}" '
set -e
BAK="/System/Library/CoreServices/SpringBoard.app/N72AP.plist.bak"
DST="/System/Library/CoreServices/SpringBoard.app/N72AP.plist"
if [ ! -f "$BAK" ] || [ -L "$BAK" ] || [ ! -O "$BAK" ] || [ ! -s "$BAK" ]; then
  echo "[!] Valid root-owned backup not found at $BAK" >&2
  exit 1
fi
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$BAK" >/dev/null
else
  head -c 6 "$BAK" | grep -Eq "^(bplist|<\?xml)"
fi
cp -f "$BAK" "${DST}.tmp"
chown root:wheel "${DST}.tmp"
chmod 644 "${DST}.tmp"
mv -f "${DST}.tmp" "$DST"
killall SpringBoard
echo "Restored verified N72AP.plist and resprung."
'
# Undo: re-enable multitasking by setting capabilities.multitasking = true in N72AP.plist
