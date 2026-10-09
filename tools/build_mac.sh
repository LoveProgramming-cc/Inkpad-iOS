#!/bin/zsh
# Make dist/Inkpad.app for this Mac (Mac Catalyst), signed ad hoc: it needs no Apple
# account and does not expire, but it is for this Mac only (Gatekeeper refuses it elsewhere
# until it is opened once with a right click > Open).
set -euo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"
BUILD="${TMPDIR:-/tmp}/inkpad-mac-build"
xcodebuild -project Inkpad.xcodeproj -scheme Inkpad -configuration Release \
  -destination 'platform=macOS,variant=Mac Catalyst' -derivedDataPath "$BUILD" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true
APP="$BUILD/Build/Products/Release-maccatalyst/Inkpad.app"
[[ -d "$APP" ]] || { echo "Build failed." >&2; exit 1; }
mkdir -p dist
rm -rf dist/Inkpad.app
cp -R "$APP" dist/
echo "dist/Inkpad.app ($(du -sh dist/Inkpad.app | cut -f1)). Move it to /Applications, or run: open dist/Inkpad.app"
