#!/bin/zsh
# Build Inkpad and install it on an iPad that this Mac can reach (USB, or Wi-Fi once
# "Connect via network" is ticked for it in Xcode > Window > Devices and Simulators).
#
#   tools/install.sh              the first reachable iPad
#   tools/install.sh <udid|name>  that device
#
# Installing over an existing copy keeps its notebooks and settings. With a free Apple ID
# the signature lasts 7 days; running this again renews it (see README).
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
BUILD="${TMPDIR:-/tmp}/inkpad-device-build"   # not inside the project: the build database dislikes synced folders

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
  LIST=$(mktemp)
  xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1 || true
  DEVICE=$(/usr/bin/python3 - "$LIST" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))['result']['devices']
except Exception:
    devices = []
for d in devices:
    hw, link = d.get('hardwareProperties', {}), d.get('connectionProperties', {})
    if hw.get('deviceType') == 'iPad' and hw.get('reality') == 'physical' and link.get('tunnelState') != 'unavailable':
        print(hw.get('udid', ''))
        break
PY
)
  rm -f "$LIST"
fi
if [[ -z "$DEVICE" ]]; then
  echo "No iPad within reach. Plug it in, or unlock it on the same Wi-Fi." >&2
  exit 2
fi

echo "Building for $DEVICE…"
LOG=$(mktemp)
# Device registration: an iPad this Apple ID has not signed for before is added to its profile.
if ! xcodebuild -project Inkpad.xcodeproj -scheme Inkpad -configuration Release \
  -destination "id=$DEVICE" -derivedDataPath "$BUILD" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | sort -u >&2 || true
  rm -f "$LOG"
  echo "Build failed, nothing was installed. If it says 'No Accounts': sign in under Xcode > Settings > Accounts, then run this again." >&2
  exit 1
fi
rm -f "$LOG"
APP="$BUILD/Build/Products/Release-iphoneos/Inkpad.app"

echo "Installing…"
xcrun devicectl device install app --device "$DEVICE" "$APP"

if [[ -f "$APP/embedded.mobileprovision" ]]; then
  UNTIL=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null || true)
  [[ -n "$UNTIL" ]] && echo "Signed until $UNTIL"
fi
