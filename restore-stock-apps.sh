#!/usr/bin/env bash
set -euo pipefail

# Restores allowlisted stock iOS 4.1 apps from /var/mobile/DisabledApps and
# allowlisted root-owned Apple launch daemons from /System/Library/LaunchDaemons.disabled.
LIK_BIN="/home/erik/Legacy-iOS-Kit/bin/linux/x86_64"
LIK_LIB="${LIK_BIN}/lib"
PORT="${IPROXY_PORT:-2241}"
KNOWN_HOSTS="${IPOD_KNOWN_HOSTS:-$HOME/.ssh/echolegacy_ipod_known_hosts}"

if [ -z "${IPOD_SSH_KEY:-}" ] && [ -z "${IPOD_PASS:-}" ]; then
  echo "[!] Error: Set IPOD_SSH_KEY or IPOD_PASS before running restore-stock-apps.sh (no default 'alpine')." >&2
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

validate_plist() {
  f="$1"
  [ -f "$f" ] && [ ! -L "$f" ] && [ -s "$f" ] || return 1
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$f" >/dev/null 2>&1 || return 1
  else
    head -c 6 "$f" | grep -Eq "^(bplist|<\?xml)" || return 1
  fi
  return 0
}

if [ -d /var/mobile/DisabledApps ] && [ ! -L /var/mobile/DisabledApps ]; then
  for app in /var/mobile/DisabledApps/*.app; do
    [ -d "$app" ] && [ ! -L "$app" ] || continue
    base=$(basename "$app")
    case "$base" in
      AccountSettings.app|AppStore.app|Calculator.app|Contacts.app|GameCenter~iphone.app|Maps.app|MobileCal.app|MobileMail.app|MobileNotes.app|MobileMusicPlayer.app|MobileSafari.app|MobileSlideShow.app|MobileTimer.app|Preferences.app|Stocks.app|VoiceMemos.app|Weather.app|Web.app|WebSheet.app|YouTube.app|iTunes.app)
        ;;
      *)
        echo "[!] Skipping non-allowlisted bundle in DisabledApps: $base" >&2
        continue
        ;;
    esac
    if ! validate_plist "$app/Info.plist"; then
      echo "[!] Skipping $base: invalid or symlinked Info.plist" >&2
      continue
    fi
    if find "$app" -type l | grep -q .; then
      echo "[!] Skipping $base: contains symlinks" >&2
      continue
    fi
    chown -R root:wheel "$app"
    chmod -R go-w "$app"
    rm -rf "/Applications/$base"
    mv "$app" "/Applications/$base"
  done
fi

if [ -d /System/Library/LaunchDaemons.disabled ] && [ ! -L /System/Library/LaunchDaemons.disabled ]; then
  for p in /System/Library/LaunchDaemons.disabled/*.plist; do
    [ -f "$p" ] && [ ! -L "$p" ] && [ -O "$p" ] || continue
    base=$(basename "$p")
    case "$base" in
      com.apple.*.plist)
        ;;
      *)
        echo "[!] Skipping non-Apple LaunchDaemon plist: $base" >&2
        continue
        ;;
    esac
    if ! validate_plist "$p"; then
      echo "[!] Skipping invalid LaunchDaemon plist: $base" >&2
      continue
    fi
    chown root:wheel "$p"
    chmod 644 "$p"
    mv "$p" "/System/Library/LaunchDaemons/$base"
    launchctl load -w "/System/Library/LaunchDaemons/$base" 2>/dev/null || true
  done
fi

su mobile -c uicache
killall SpringBoard
echo "Restored allowlisted stock apps & daemons and resprung."
'
# Undo: re-move apps/daemons back to DisabledApps / LaunchDaemons.disabled
