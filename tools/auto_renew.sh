#!/bin/zsh
# Let this Mac renew Inkpad's signature on the iPad by itself.
#
#   tools/auto_renew.sh on    run tools/install.sh every 6 hours (and at login)
#   tools/auto_renew.sh off   stop doing that
#
# Each run does nothing unless the iPad is reachable. Xcode has to stay signed in to the
# Apple ID (Xcode > Settings > Accounts), and the iPad needs "Connect via network" ticked
# in Xcode > Window > Devices and Simulators so that it works without a cable.
# The log is ~/Library/Logs/inkpad-renew.log.
set -euo pipefail
LABEL=io.github.inkpad.renew
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SCRIPT="${0:A:h}/install.sh"

case "${1:-}" in
on)
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$LABEL</string>
	<key>ProgramArguments</key>
	<array><string>/bin/zsh</string><string>$SCRIPT</string></array>
	<key>StartInterval</key><integer>21600</integer>
	<key>RunAtLoad</key><true/>
	<key>StandardOutPath</key><string>$HOME/Library/Logs/inkpad-renew.log</string>
	<key>StandardErrorPath</key><string>$HOME/Library/Logs/inkpad-renew.log</string>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "Auto-renew is on. Log: ~/Library/Logs/inkpad-renew.log"
  ;;
off)
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Auto-renew is off."
  ;;
*)
  echo "usage: $0 on|off" >&2
  exit 64
  ;;
esac
