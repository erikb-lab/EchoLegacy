#!/usr/bin/env bash
set -uo pipefail

# Reverts /System/Library/CoreServices/SpringBoard.app/N72AP.plist from .bak and resprings.
LIK_BIN="/home/erik/Legacy-iOS-Kit/bin/linux/x86_64"
LIK_LIB="${LIK_BIN}/lib"
PORT="${IPROXY_PORT:-2235}"
PASS="${IPOD_PASS:-alpine}"

LD_LIBRARY_PATH="$LIK_LIB" "$LIK_BIN/iproxy" "$PORT" 22 >/dev/null 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
sleep 1

SSH_OPTS="-n -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"
env LD_LIBRARY_PATH="$LIK_LIB" "$LIK_BIN/sshpass" -p "$PASS" "$LIK_BIN/ssh" $SSH_OPTS -p "$PORT" root@127.0.0.1 \
  'if [ -f /System/Library/CoreServices/SpringBoard.app/N72AP.plist.bak ]; then cp /System/Library/CoreServices/SpringBoard.app/N72AP.plist.bak /System/Library/CoreServices/SpringBoard.app/N72AP.plist && killall SpringBoard && echo "Restored N72AP.plist and resprung."; else echo "No backup found."; exit 1; fi'
# Undo: re-enable multitasking by setting capabilities.multitasking = true in N72AP.plist
