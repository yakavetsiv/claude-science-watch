#!/bin/zsh
# Installs (or reinstalls) the Claude Science Watch helper as a launchd agent.
# Uninstall: ./install.sh --uninstall
set -euo pipefail

LABEL="com.viprorok.claude-science-watch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/claude-science-watch.log"
SCRIPT="$(cd "$(dirname "$0")" && pwd)/csw.js"
NODE="$(command -v node || echo "$HOME/.local/node/bin/node")"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$PLIST"
  echo "Uninstalled $LABEL"
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE</string>
    <string>$SCRIPT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>60</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL (node: $NODE)"
echo "Log: $LOG"
