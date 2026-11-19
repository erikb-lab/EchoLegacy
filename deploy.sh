#!/usr/bin/env bash
set -uo pipefail

# Deploy EchoLegacy.app to a plugged-in jailbroken iPod touch 2G over USB SSH (iproxy)
# Default root password on jailbroken iOS is 'alpine' (override with IPOD_PASS=...)

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="${DIR}/build/EchoLegacy.app"
LIK_BIN="/home/erik/Legacy-iOS-Kit/bin/linux/x86_64"
LIK_LIB="${LIK_BIN}/lib"
PORT="${IPROXY_PORT:-2222}"
PASS="${IPOD_PASS:-alpine}"

if [ ! -d "$APP_SRC" ]; then
  echo "[!] Build artifact not found at $APP_SRC — run 'make' in $DIR first."
  exit 1
fi

echo "[1/5] Checking USB connection to iPod..."
if ! LD_LIBRARY_PATH="$LIK_LIB" "$LIK_BIN/ideviceinfo" -k ProductType >/dev/null 2>&1; then
  echo "[!] No iOS device detected via USB."
  exit 1
fi

echo "[2/5] Starting USB SSH tunnel on 127.0.0.1:${PORT} -> iPod:22..."
LD_LIBRARY_PATH="$LIK_LIB" "$LIK_BIN/iproxy" "$PORT" 22 >/dev/null 2>&1 &
IPROXY_PID=$!
trap 'kill "$IPROXY_PID" 2>/dev/null || true' EXIT
sleep 1

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=8 -o KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa"
SSH_CMD=(env LD_LIBRARY_PATH="$LIK_LIB" "$LIK_BIN/sshpass" -p "$PASS" "$LIK_BIN/ssh" $SSH_OPTS -p "$PORT" root@127.0.0.1)

echo "[3/5] Uploading EchoLegacy.app to /Applications/EchoLegacy.app..."
if ! tar -C "${DIR}/build" -cf - EchoLegacy.app | \
  "${SSH_CMD[@]}" \
    "killall EchoLegacy 2>/dev/null || true; rm -rf /Applications/EchoLegacy.app && tar -C /Applications -xf - && chown -R root:wheel /Applications/EchoLegacy.app && chmod 755 /Applications/EchoLegacy.app/EchoLegacy"; then
  echo "[!] SSH upload failed. Verify OpenSSH is installed and IPOD_PASS is correct (default: alpine)."
  exit 1
fi

echo "[4/5] Refreshing SpringBoard icon cache (uicache + icon cache reset)..."
"${SSH_CMD[@]}" "rm -rf /var/mobile/Library/Caches/com.apple.IconsCache /var/mobile/Library/Caches/com.apple.springboard.sharedimagecache 2>/dev/null || true; su mobile -c uicache && killall SpringBoard" || echo "[!] uicache returned non-zero; try respringing if icon doesn't appear."

echo "[5/5] Verifying installed binary on iPod..."
"${SSH_CMD[@]}" "ls -lh /Applications/EchoLegacy.app/EchoLegacy" || exit 1

echo "[+] Done! EchoLegacy is installed on your iPod touch 2G."
# Undo: ssh -p 2222 root@127.0.0.1 "rm -rf /Applications/EchoLegacy.app && su mobile -c uicache"
