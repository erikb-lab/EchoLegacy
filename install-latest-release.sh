#!/usr/bin/env bash
set -uo pipefail

# Download the latest EchoLegacy GitHub release (armv6 iOS 4.1) and install it
# onto a USB-connected jailbroken iPod touch 2G from any Linux PC.
#
# Usage:
#   ./install-latest-release.sh
#   IPOD_SSH_KEY=~/.ssh/id_rsa ./install-latest-release.sh
#   IPOD_PASS='<root-password>' ./install-latest-release.sh

REPO="${ECHOLEGACY_REPO:-erikb-lab/EchoLegacy}"
RELEASE_BASE="https://github.com/${REPO}/releases/download/latest"
PORT="${IPROXY_PORT:-2222}"
KNOWN_HOSTS="${IPOD_KNOWN_HOSTS:-$HOME/.ssh/echolegacy_ipod_known_hosts}"

if [ -d "/home/erik/esp/.tmp" ]; then
  WORK_DIR="/home/erik/esp/.tmp/echolegacy-install"
else
  WORK_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/echolegacy-install"
fi

LIK_BIN="/home/erik/Legacy-iOS-Kit/bin/linux/x86_64"
LIK_LIB="${LIK_BIN}/lib"
if [ -x "${LIK_BIN}/iproxy" ] && [ -x "${LIK_BIN}/ideviceinfo" ]; then
  IPROXY_CMD=(env LD_LIBRARY_PATH="$LIK_LIB" "${LIK_BIN}/iproxy")
  IDEVICEINFO_CMD=(env LD_LIBRARY_PATH="$LIK_LIB" "${LIK_BIN}/ideviceinfo")
  SSH_BIN="${LIK_BIN}/ssh"
  SSHPASS_BIN="${LIK_BIN}/sshpass"
  SSH_ENV=(env LD_LIBRARY_PATH="$LIK_LIB")
else
  IPROXY_CMD=(iproxy)
  IDEVICEINFO_CMD=(ideviceinfo)
  SSH_BIN="$(command -v ssh || true)"
  SSHPASS_BIN="$(command -v sshpass || true)"
  SSH_ENV=()
fi

for req in curl unzip tar sha256sum; do
  if ! command -v "$req" >/dev/null 2>&1; then
    echo "[!] Missing required tool: $req (install it with your package manager)." >&2
    exit 1
  fi
done
if [ -z "${SSH_BIN:-}" ] || [ ! -x "$SSH_BIN" ]; then
  echo "[!] Missing ssh client." >&2
  exit 1
fi
if ! command -v "${IPROXY_CMD[${#IPROXY_CMD[@]}-1]}" >/dev/null 2>&1 && [ ! -x "${IPROXY_CMD[${#IPROXY_CMD[@]}-1]}" ]; then
  echo "[!] Missing iproxy (install libimobiledevice-utils / usbmuxd)." >&2
  exit 1
fi

echo "[1/6] Downloading latest EchoLegacy release from github.com/${REPO}..."
mkdir -p "$WORK_DIR" || { echo "[!] Failed creating $WORK_DIR" >&2; exit 1; }
rm -rf "${WORK_DIR}/Payload" "${WORK_DIR}/EchoLegacy.ipa" "${WORK_DIR}/version.json"

if ! curl -fsSL "${RELEASE_BASE}/version.json" -o "${WORK_DIR}/version.json"; then
  echo "[!] Failed downloading version.json from ${RELEASE_BASE}/version.json" >&2
  exit 1
fi
if ! curl -fsSL "${RELEASE_BASE}/EchoLegacy.ipa" -o "${WORK_DIR}/EchoLegacy.ipa"; then
  echo "[!] Failed downloading EchoLegacy.ipa from ${RELEASE_BASE}/EchoLegacy.ipa" >&2
  exit 1
fi

echo "[2/6] Extracting & verifying SHA-256 checksums against version.json..."
if ! unzip -qo "${WORK_DIR}/EchoLegacy.ipa" -d "${WORK_DIR}"; then
  echo "[!] Failed extracting EchoLegacy.ipa" >&2
  exit 1
fi

APP_SRC="${WORK_DIR}/Payload/EchoLegacy.app"
if [ ! -f "$APP_SRC/EchoLegacy" ] || [ ! -f "$APP_SRC/Info.plist" ] || [ ! -f "$APP_SRC/cacert.pem" ]; then
  echo "[!] Extracted EchoLegacy.app is incomplete." >&2
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  if ! python3 - "${WORK_DIR}/version.json" "${WORK_DIR}/EchoLegacy.ipa" "$APP_SRC" << 'PY'
import hashlib, json, os, sys
meta = json.load(open(sys.argv[1]))
ipa_path, app_dir = sys.argv[2], sys.argv[3]
checks = [
    ("EchoLegacy.ipa", ipa_path),
    ("EchoLegacy", os.path.join(app_dir, "EchoLegacy")),
    ("Info.plist", os.path.join(app_dir, "Info.plist")),
    ("cacert.pem", os.path.join(app_dir, "cacert.pem")),
]
assets = meta.get("assets", {})
for name, path in checks:
    exp = assets.get(name, {})
    data = open(path, "rb").read()
    got_sha = hashlib.sha256(data).hexdigest()
    if exp.get("size") and len(data) != exp["size"]:
        sys.exit(f"[!] Size mismatch for {name}: got {len(data)}, expected {exp['size']}")
    if exp.get("sha256") and got_sha != exp["sha256"]:
        sys.exit(f"[!] SHA-256 mismatch for {name}: got {got_sha}, expected {exp['sha256']}")
print(f"    Verified EchoLegacy v{meta.get('version','?')} Build #{meta.get('build','?')} ({meta.get('sha','?')})")
PY
  then
    exit 1
  fi
fi

BIN_SIZE="$(stat -c '%s' "$APP_SRC/EchoLegacy")"
PL_SIZE="$(stat -c '%s' "$APP_SRC/Info.plist")"
CA_SIZE="$(stat -c '%s' "$APP_SRC/cacert.pem")"
BIN_SHA256="$(sha256sum "$APP_SRC/EchoLegacy" | awk '{print $1}')"
PL_SHA256="$(sha256sum "$APP_SRC/Info.plist" | awk '{print $1}')"
CA_SHA256="$(sha256sum "$APP_SRC/cacert.pem" | awk '{print $1}')"

echo "[3/6] Checking USB connection to iPod..."
if ! "${IDEVICEINFO_CMD[@]}" -k ProductType >/dev/null 2>&1; then
  echo "[!] No iOS device detected via USB. Plug in your iPod touch 2G and re-run this script." >&2
  exit 1
fi

if [ -z "${IPOD_SSH_KEY:-}" ] && [ -z "${IPOD_PASS:-}" ]; then
  read -r -s -p "Enter iPod root SSH password: " IPOD_PASS
  echo ""
  if [ -z "$IPOD_PASS" ]; then
    echo "[!] Empty password aborted." >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$KNOWN_HOSTS")"
chmod 700 "$(dirname "$KNOWN_HOSTS")" 2>/dev/null || true

echo "[4/6] Starting USB SSH tunnel on 127.0.0.1:${PORT} -> iPod:22..."
"${IPROXY_CMD[@]}" "$PORT" 22 >/dev/null 2>&1 &
IPROXY_PID=$!
trap 'kill "$IPROXY_PID" 2>/dev/null || true' EXIT
sleep 1

SSH_OPTS=(
  -o StrictHostKeyChecking=accept-new
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
  -o ConnectTimeout=8
  -o KexAlgorithms=+diffie-hellman-group14-sha1,diffie-hellman-group1-sha1
  -o HostKeyAlgorithms=+ssh-rsa
  -o PubkeyAcceptedAlgorithms=+ssh-rsa
)

if [ -n "${IPOD_SSH_KEY:-}" ]; then
  if [ ! -f "$IPOD_SSH_KEY" ]; then
    echo "[!] IPOD_SSH_KEY not found: $IPOD_SSH_KEY" >&2
    exit 1
  fi
  SSH_CMD=("${SSH_ENV[@]}" "$SSH_BIN" "${SSH_OPTS[@]}" -o BatchMode=yes -i "$IPOD_SSH_KEY" -p "$PORT" root@127.0.0.1)
elif [ -n "${SSHPASS_BIN:-}" ] && [ -x "$SSHPASS_BIN" ]; then
  export SSHPASS="$IPOD_PASS"
  SSH_CMD=("${SSH_ENV[@]}" "$SSHPASS_BIN" -e "$SSH_BIN" "${SSH_OPTS[@]}" -p "$PORT" root@127.0.0.1)
else
  echo "[!] sshpass not installed; SSH will prompt for password directly."
  SSH_CMD=("${SSH_ENV[@]}" "$SSH_BIN" "${SSH_OPTS[@]}" -p "$PORT" root@127.0.0.1)
fi

echo "[5/6] Uploading, verifying, and installing /Applications/EchoLegacy.app..."
if ! tar -C "${WORK_DIR}/Payload" -cf - EchoLegacy.app | \
  "${SSH_CMD[@]}" "
    set -e
    STAGE_DIR=\"/tmp/EchoLegacy.stage.\$\$\"
    rm -rf \"\$STAGE_DIR\"
    mkdir -p \"\$STAGE_DIR\"
    chmod 700 \"\$STAGE_DIR\"
    tar -C \"\$STAGE_DIR\" -xf -

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

    chown -R root:wheel \"\$STAGE_DIR/EchoLegacy.app\"
    chmod 755 \"\$STAGE_DIR/EchoLegacy.app\" \"\$STAGE_DIR/EchoLegacy.app/EchoLegacy\"
    find \"\$STAGE_DIR/EchoLegacy.app\" -type f ! -name 'EchoLegacy' -exec chmod 644 {} +

    killall EchoLegacy 2>/dev/null || true
    rm -rf /Applications/EchoLegacy.app
    mv \"\$STAGE_DIR/EchoLegacy.app\" /Applications/EchoLegacy.app
    rm -rf \"\$STAGE_DIR\"
  "; then
  echo "[!] Upload/install failed." >&2
  exit 1
fi

echo "[6/6] Refreshing SpringBoard icon cache and verifying install..."
"${SSH_CMD[@]}" "rm -rf /var/mobile/Library/Caches/com.apple.IconsCache /var/mobile/Library/Caches/com.apple.springboard.sharedimagecache 2>/dev/null || true; su mobile -c uicache && killall SpringBoard" || true
"${SSH_CMD[@]}" "ls -ld /Applications/EchoLegacy.app && ls -lh /Applications/EchoLegacy.app/EchoLegacy /Applications/EchoLegacy.app/cacert.pem" || exit 1

echo "[+] Done! Latest EchoLegacy GitHub release is installed on your iPod touch 2G."
# Undo: ssh -p 2222 root@127.0.0.1 "rm -rf /Applications/EchoLegacy.app && su mobile -c uicache && killall SpringBoard"
