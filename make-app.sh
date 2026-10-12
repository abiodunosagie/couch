#!/bin/sh
# Build "TV Remote.app" in ~/Applications. Double-clicking it starts the local
# server (if it is not already running) and opens the remote window.
set -eu

PROJECT="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/TV Remote.app"
UV="$(command -v uv)"
PORT=8765

mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TV Remote</string>
  <key>CFBundleDisplayName</key><string>TV Remote</string>
  <key>CFBundleIdentifier</key><string>com.abiodun.tvremote</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>tvremote</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cat > "$APP/Contents/MacOS/tvremote" <<SCRIPT
#!/bin/sh
URL="http://127.0.0.1:$PORT/"
LOG="\$HOME/Library/Logs/tvremote.log"

if ! /usr/bin/curl -fs "\${URL}health" >/dev/null 2>&1; then
  mkdir -p "\$HOME/Library/Logs"
  cd "$PROJECT"
  nohup "$UV" run --quiet python tvremote.py serve --port $PORT >>"\$LOG" 2>&1 &
  i=0
  until /usr/bin/curl -fs "\${URL}health" >/dev/null 2>&1; do
    i=\$((i + 1))
    if [ "\$i" -gt 240 ]; then
      /usr/bin/osascript -e 'display alert "TV Remote could not start" message "See ~/Library/Logs/tvremote.log"'
      exit 1
    fi
    sleep 0.25
  done
fi

# Chrome's app mode gives a clean window without tabs; fall back to the default browser.
if [ -d "/Applications/Google Chrome.app" ]; then
  open -na "Google Chrome" --args --app="\$URL" --window-size=820,640
else
  open "\$URL"
fi
SCRIPT

chmod +x "$APP/Contents/MacOS/tvremote"
touch "$APP"
echo "Built $APP"
