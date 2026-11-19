#!/usr/bin/env bash
set -euo pipefail

# Deploy EchoLegacy.app to a plugged-in jailbroken iPod touch 2G over USB SSH (iproxy).
# Security hardening:
#   - No hardcoded default 'alpine' password.
#   - Supports SSH key auth first (IPOD_SSH_KEY=/path/to/id_rsa) or explicit IPOD_PASS env var.
#   - Uses dedicated known_hosts file with StrictHostKeyChecking=accept-new.
#   - Stages upload to a root-owned temp directory, verifies file sizes & hashes on device,
#     and installs /Applications/EchoLegacy.app owned by mobile:mobile (0755 dir/binary, 0644 resources)
#     so on-device 1-tap OTA self-updates can atomically replace the bundle.

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="${DIR}/build/EchoLegacy.app"
LIK_BIN="/home/erik/Legacy-iOS-Kit/bin/linux/x86_64"
LIK_LIB="${LIK_BIN}/lib"
PORT="${IPROXY_PORT:-2222}"
KNOWN_HOSTS="${IPOD_KNOWN_HOSTS:-$HOME/.ssh/echolegacy_ipod_known_hosts}"

if [ ! -d "$APP_SRC" ] || [ ! -f "$APP_SRC/EchoLegacy" ] || [ ! -f "$APP_SRC/Info.plist" ] || [ ! -f "$APP_SRC/cacert.pem" ]; then
  echo "[!] Build artifact incomplete or not found at $APP_SRC — run 'make' in $DIR first."
  exit 1
fi

if [ -z "${IPOD_SSH_KEY:-}" ] && [ -z "${IPOD_PASS:-}" ]; then
  cat >&2 <<'EOF'
[!] Error: Neither IPOD_SSH_KEY nor IPOD_PASS is set.
    Refusing to use the insecure default jailbreak password ('alpine').
    Hardening recommendations for your iPod touch 2G:
      1. Change both 'root' and 'mobile' passwords immediately on-device via 'passwd'.
      2. Install an SSH public key in /var/root/.ssh/authorized_keys and deploy with:
           IPOD_SSH_KEY=~/.ssh/id_rsa ./deploy.sh
         Or explicitly export your custom root password for this session:
           IPOD_PASS='<your-root-password>' ./deploy.sh
      3. Disable OpenSSH (via SBSettings or launchctl) when not actively deploying.
EOF
  exit 1
fi

mkdir -p "$(dirname "$KNOWN_HOSTS")"
chmod 700 "$(dirname "$KNOWN_HOSTS")" 2>/dev/null || true

BIN_SIZE="$(stat -c '%s' "$APP_SRC/EchoLegacy")"
PL_SIZE="$(stat -c '%s' "$APP_SRC/Info.plist")"
CA_SIZE="$(stat -c '%s' "$APP_SRC/cacert.pem")"
BIN_SHA256="$(sha256sum "$APP_SRC/EchoLegacy" | awk '{print $1}')"
PL_SHA256="$(sha256sum "$APP_SRC/Info.plist" | awk '{print $1}')"
CA_SHA256="$(sha256sum "$APP_SRC/cacert.pem" | awk '{print $1}')"

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

SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
  -o ConnectTimeout=8
  -o KexAlgorithms=+diffie-hellman-group14-sha1
  -o HostKeyAlgorithms=+ssh-rsa
  -o PubkeyAcceptedAlgorithms=+ssh-rsa
)

if [ -n "${IPOD_SSH_KEY:-}" ]; then
  if [ ! -f "$IPOD_SSH_KEY" ]; then
    echo "[!] IPOD_SSH_KEY file not found: $IPOD_SSH_KEY"
    exit 1
  fi
  SSH_CMD=(env LD_LIBRARY_PATH="$LIK_LIB" "$LIK_BIN/ssh" "${SSH_OPTS[@]}" -o BatchMode=yes -i "$IPOD_SSH_KEY" -p "$PORT" root@127.0.0.1)
else
  export SSHPASS="$IPOD_PASS"
  SSH_CMD=(env LD_LIBRARY_PATH="$LIK_LIB" SSHPASS="$SSHPASS" "$LIK_BIN/sshpass" -e "$LIK_BIN/ssh" "${SSH_OPTS[@]}" -p "$PORT" root@127.0.0.1)
fi

echo "[3/5] Staging and verifying EchoLegacy.app on device..."
if ! tar -C "${DIR}/build" -cf - EchoLegacy.app | \
  "${SSH_CMD[@]}" "
    set -e
    STAGE_DIR=\"/tmp/EchoLegacy.stage.\$\$\"
    rm -rf \"\$STAGE_DIR\"
    mkdir -p \"\$STAGE_DIR\"
    chmod 700 \"\$STAGE_DIR\"
    tar -C \"\$STAGE_DIR\" -xf -

    if [ ! -f \"\$STAGE_DIR/EchoLegacy.app/EchoLegacy\" ] || \
       [ ! -f \"\$STAGE_DIR/EchoLegacy.app/Info.plist\" ] || \
       [ ! -f \"\$STAGE_DIR/EchoLegacy.app/cacert.pem\" ]; then
      echo '[!] Staged bundle is missing required files' >&2
      rm -rf \"\$STAGE_DIR\"
      exit 1
    fi

    GOT_BIN_SZ=\$(wc -c < \"\$STAGE_DIR/EchoLegacy.app/EchoLegacy\" | tr -d ' ')
    GOT_PL_SZ=\$(wc -c < \"\$STAGE_DIR/EchoLegacy.app/Info.plist\" | tr -d ' ')
    GOT_CA_SZ=\$(wc -c < \"\$STAGE_DIR/EchoLegacy.app/cacert.pem\" | tr -d ' ')
    if [ \"\$GOT_BIN_SZ\" != '${BIN_SIZE}' ] || [ \"\$GOT_PL_SZ\" != '${PL_SIZE}' ] || [ \"\$GOT_CA_SZ\" != '${CA_SIZE}' ]; then
      echo '[!] Staged file size mismatch on device' >&2
      rm -rf \"\$STAGE_DIR\"
      exit 1
    fi

    if command -v sha256sum >/dev/null 2>&1; then
      echo '${BIN_SHA256}  '\"\$STAGE_DIR/EchoLegacy.app/EchoLegacy\" | sha256sum -c - >/dev/null
      echo '${PL_SHA256}  '\"\$STAGE_DIR/EchoLegacy.app/Info.plist\" | sha256sum -c - >/dev/null
      echo '${CA_SHA256}  '\"\$STAGE_DIR/EchoLegacy.app/cacert.pem\" | sha256sum -c - >/dev/null
    elif command -v openssl >/dev/null 2>&1; then
      [ \"\$(openssl dgst -sha256 \"\$STAGE_DIR/EchoLegacy.app/EchoLegacy\" | awk '{print \$NF}')\" = '${BIN_SHA256}' ]
      [ \"\$(openssl dgst -sha256 \"\$STAGE_DIR/EchoLegacy.app/Info.plist\" | awk '{print \$NF}')\" = '${PL_SHA256}' ]
      [ \"\$(openssl dgst -sha256 \"\$STAGE_DIR/EchoLegacy.app/cacert.pem\" | awk '{print \$NF}')\" = '${CA_SHA256}' ]
    fi

    chown -R mobile:mobile \"\$STAGE_DIR/EchoLegacy.app\"
    chmod 755 \"\$STAGE_DIR/EchoLegacy.app\" \"\$STAGE_DIR/EchoLegacy.app/EchoLegacy\"
    find \"\$STAGE_DIR/EchoLegacy.app\" -type f ! -name 'EchoLegacy' -exec chmod 644 {} +

    killall EchoLegacy 2>/dev/null || true
    rm -rf /Applications/EchoLegacy.app
    mv \"\$STAGE_DIR/EchoLegacy.app\" /Applications/EchoLegacy.app
    rm -rf \"\$STAGE_DIR\"
  "; then
  echo "[!] SSH staged upload/verification failed."
  exit 1
fi

echo "[4/5] Refreshing SpringBoard icon cache (uicache + icon cache reset)..."
"${SSH_CMD[@]}" "rm -rf /var/mobile/Library/Caches/com.apple.IconsCache /var/mobile/Library/Caches/com.apple.springboard.sharedimagecache 2>/dev/null || true; su mobile -c uicache && killall SpringBoard" || echo "[!] uicache returned non-zero; try respringing if icon doesn't appear."

echo "[5/5] Verifying installed binary & mobile:mobile ownership on iPod..."
"${SSH_CMD[@]}" "ls -ld /Applications/EchoLegacy.app && ls -lh /Applications/EchoLegacy.app/EchoLegacy /Applications/EchoLegacy.app/cacert.pem" || exit 1

echo "[+] Done! EchoLegacy is installed on your iPod touch 2G."
# Undo: ssh -p 2222 root@127.0.0.1 "rm -rf /Applications/EchoLegacy.app && su mobile -c uicache"
