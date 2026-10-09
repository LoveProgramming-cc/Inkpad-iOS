#!/bin/zsh
# Make dist/Inkpad.ipa, unsigned, for AltStore or SideStore to sign and keep renewed.
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
BUILD="${TMPDIR:-/tmp}/inkpad-ipa-build"
xcodebuild -project Inkpad.xcodeproj -scheme Inkpad -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath "$BUILD" CODE_SIGNING_ALLOWED=NO build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP="$BUILD/Build/Products/Release-iphoneos/Inkpad.app"
[[ -d "$APP" ]] || { echo "Build failed." >&2; exit 1; }
rm -rf "$BUILD/Payload"
mkdir -p "$BUILD/Payload" dist
cp -R "$APP" "$BUILD/Payload/"
rm -f dist/Inkpad.ipa
(cd "$BUILD" && zip -qry "$ROOT/dist/Inkpad.ipa" Payload)
echo "dist/Inkpad.ipa ($(du -h dist/Inkpad.ipa | cut -f1))"
