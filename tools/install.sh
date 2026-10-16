#!/bin/zsh
# Build Inkpad and install it on an iPad or iPhone that this Mac can reach (USB, or Wi-Fi once
# "Connect via network" is ticked for it in Xcode > Window > Devices and Simulators).
#
#   tools/install.sh               asks which, when more than one device is within reach
#   tools/install.sh <udid|name>   that device (part of its name will do: "iPhone")
#   tools/install.sh --all         every device within reach
#   tools/install.sh --list        only show the devices
#   tools/install.sh --renew …     sign afresh, for another 7 days from now (with any of the above)
#
# Installing over an existing copy keeps its notebooks and settings. With a free Apple ID
# the signature lasts 7 days. Xcode keeps using the profile it has until that runs out, so a
# plain run before then signs only until the same day; --renew puts that profile aside first,
# and Xcode asks Apple for a new one.
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
BUILD="${TMPDIR:-/tmp}/inkpad-device-build"   # not inside the project: the build database dislikes synced folders

# The iPads and iPhones within reach, one "udid<TAB>name (model)" a line.
LIST=$(mktemp)
xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1 || true
FOUND=$(/usr/bin/python3 - "$LIST" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))['result']['devices']
except Exception:
    devices = []
for d in devices:
    hw, link, about = d.get('hardwareProperties', {}), d.get('connectionProperties', {}), d.get('deviceProperties', {})
    if hw.get('deviceType') in ('iPad', 'iPhone') and hw.get('reality') == 'physical' and link.get('tunnelState') != 'unavailable':
        print('%s\t%s (%s)' % (hw.get('udid', ''), about.get('name', '?'), hw.get('marketingName') or hw.get('deviceType')))
PY
)
rm -f "$LIST"
UDIDS=("${(@f)$(print -r -- "$FOUND" | cut -f1)}")
NAMES=("${(@f)$(print -r -- "$FOUND" | cut -f2)}")
[[ -z "$FOUND" ]] && UDIDS=() NAMES=()

RENEW=0
WANT=""
for ARG in "$@"; do
  if [[ "$ARG" == "--renew" ]]; then RENEW=1; else WANT="$ARG"; fi
done
if [[ "$WANT" == "--list" ]]; then
  for i in {1..${#UDIDS}}; do echo "${UDIDS[$i]}  ${NAMES[$i]}"; done
  exit 0
fi
TARGETS=()
if [[ "$WANT" == "--all" ]]; then
  TARGETS=($UDIDS)
elif [[ -n "$WANT" ]]; then
  for i in {1..${#UDIDS}}; do
    if [[ "${UDIDS[$i]}" == "$WANT" || "${NAMES[$i]:l}" == *"${WANT:l}"* ]]; then TARGETS+=("${UDIDS[$i]}"); fi
  done
  # Not in the list (asleep, perhaps): try it as given.
  (( ${#TARGETS} )) || TARGETS=("$WANT")
elif (( ${#UDIDS} == 1 )); then
  TARGETS=($UDIDS)
elif (( ${#UDIDS} > 1 )); then
  if [[ ! -t 0 ]]; then
    echo "More than one device within reach; say which (name or udid), or --all:" >&2
    for i in {1..${#UDIDS}}; do echo "  ${UDIDS[$i]}  ${NAMES[$i]}" >&2; done
    exit 2
  fi
  echo "Install on which device?"
  for i in {1..${#UDIDS}}; do echo "  $i) ${NAMES[$i]}"; done
  echo "  a) all of them"
  read "PICK?> "
  if [[ "$PICK" == "a" ]]; then
    TARGETS=($UDIDS)
  elif [[ "$PICK" == <-> ]] && (( PICK >= 1 && PICK <= ${#UDIDS} )); then
    TARGETS=("${UDIDS[$PICK]}")
  else
    echo "Nothing chosen." >&2
    exit 2
  fi
fi
if (( ${#TARGETS} == 0 )); then
  echo "No iPad or iPhone within reach. Plug it in, or unlock it on the same Wi-Fi." >&2
  exit 2
fi

# The profiles Xcode keeps for the app itself, put aside (not deleted) so that it fetches a new
# one; they come back if nothing could be built.
ASIDE=""
if (( RENEW )); then
  PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
  APP_ID=$(grep -o "PRODUCT_BUNDLE_IDENTIFIER = [^;]*" Inkpad.xcodeproj/project.pbxproj | grep -v "\.tests$\|\.uitests$\|= NO$" | head -1 | sed 's/.*= //')
  ASIDE="${${TMPDIR:-/tmp}%/}/inkpad-old-profiles/$(date +%Y%m%d-%H%M%S)"
  for F in "$PROFILES"/*.mobileprovision(N); do
    ID=$(security cms -D -i "$F" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)
    if [[ "$ID" == *".$APP_ID" ]]; then
      mkdir -p "$ASIDE"
      mv "$F" "$ASIDE/"
    fi
  done
  if [[ -d "$ASIDE" ]]; then echo "Old signing profile put aside in $ASIDE"; else ASIDE=""; fi
fi
put_back() {
  [[ -n "$ASIDE" ]] && mv "$ASIDE"/*.mobileprovision(N) "$PROFILES/" 2>/dev/null && echo "Put the old signing profile back." >&2
  ASIDE=""
}

for DEVICE in $TARGETS; do
  echo "Building for $DEVICE…"
  LOG=$(mktemp)
  # Device registration: a device this Apple ID has not signed for before is added to its profile.
  if ! xcodebuild -project Inkpad.xcodeproj -scheme Inkpad -configuration Release \
    -destination "id=$DEVICE" -derivedDataPath "$BUILD" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u >&2 || true
    rm -f "$LOG"
    put_back
    echo "Build failed, nothing was installed. If it says 'No Accounts': sign in under Xcode > Settings > Accounts, then run this again." >&2
    exit 1
  fi
  rm -f "$LOG"
  ASIDE=""   # a new profile was made: the old one is not needed any more
  APP="$BUILD/Build/Products/Release-iphoneos/Inkpad.app"

  echo "Installing…"
  xcrun devicectl device install app --device "$DEVICE" "$APP"

  if [[ -f "$APP/embedded.mobileprovision" ]]; then
    UNTIL=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null || true)
    [[ -n "$UNTIL" ]] && echo "Signed until $UNTIL"
  fi
done
