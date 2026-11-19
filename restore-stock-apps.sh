#!/usr/bin/env bash
set -uo pipefail

# Restores apps moved to /var/mobile/DisabledApps and daemons moved to /System/Library/LaunchDaemons.disabled
LIK_BIN="/home/erik/Legacy-iOS-Kit/bin/linux/x86_64"
LIK_LIB="${LIK_BIN}/lib"
PORT="${IPROXY_PORT:-2241}"
PASS="${IPOD_PASS:-alpine}"

LD_LIBRARY_PATH="$LIK_LIB" "$LIK_BIN/iproxy" "$PORT" 22 >/dev/null 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
sleep 1

SSH_OPTS="-n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"
env LD_LIBRARY_PATH="$LIK_LIB" "$LIK_BIN/sshpass" -p "$PASS" "$LIK_BIN/ssh" $SSH_OPTS -p "$PORT" root@127.0.0.1 '
if [ -d /var/mobile/DisabledApps ]; then
  mv /var/mobile/DisabledApps/*.app /Applications/ 2>/dev/null || true
fi
if [ -d /System/Library/LaunchDaemons.disabled ]; then
  for p in /System/Library/LaunchDaemons.disabled/*.plist; do
    [ -f "$p" ] || continue
    base=$(basename "$p")
    mv "$p" "/System/Library/LaunchDaemons/$base"
    launchctl load -w "/System/Library/LaunchDaemons/$base" 2>/dev/null || true
  done
fi
su mobile -c uicache
killall SpringBoard
echo "Restored apps & daemons and resprung."
'
# Undo: re-move apps/daemons back to DisabledApps / LaunchDaemons.disabled
