#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/mac-menubar"
BINARY="$APP_DIR/.build/release/BrowserTimeMenubar"
LABEL="com.local.browsertimetracker"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

cd "$APP_DIR"
swift build -c release --disable-sandbox

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BINARY</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/tmp/browser-time-tracker.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/browser-time-tracker.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

echo "Installed and started $LABEL"
echo "Dashboard: http://127.0.0.1:38888/dashboard"
