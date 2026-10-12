#!/bin/sh
# Build Couch.app into ~/Applications.
# The app is native Swift; the TV protocol runs in the Python helper from this repo,
# which the app starts on launch and stops on quit. The app runs the helper from this
# folder, so rebuild after moving the repo.
set -eu

PROJECT="$(cd "$(dirname "$0")" && pwd)"
UV="$(command -v uv || true)"
if [ -z "$UV" ]; then
  echo "uv is not installed. Install it first: https://docs.astral.sh/uv/" >&2
  exit 1
fi

APP="$HOME/Applications/Couch.app"
BUILD="$PROJECT/build"
mkdir -p "$BUILD"

# The app runs the helper from this folder; make sure it can start before installing.
echo "Checking the helper..."
(cd "$PROJECT" && "$UV" sync --quiet && "$UV" run --quiet python -c "import server") || {
  echo "The helper does not start. Fix the error above first." >&2
  exit 1
}

echo "Compiling..."
xcrun swiftc -O -parse-as-library -target arm64-apple-macos15.0 \
  -o "$BUILD/Couch" "$PROJECT"/mac/*.swift \
  -framework AppKit -framework SwiftUI

echo "Drawing icon..."
rm -rf "$BUILD/Couch.iconset"
xcrun swift "$PROJECT/tools/make-icon.swift" "$BUILD/Couch.iconset"
iconutil -c icns "$BUILD/Couch.iconset" -o "$BUILD/Couch.icns"

# Quit the installed app (it stops its helper), and any helper an older build left on the
# port, so the new build starts its own helper with this code.
pkill -x Couch 2>/dev/null || true
pkill -f "tvremote.py serve --port 8765" 2>/dev/null || true
sleep 1

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/Couch" "$APP/Contents/MacOS/Couch"
cp "$BUILD/Couch.icns" "$APP/Contents/Resources/Couch.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Couch</string>
  <key>CFBundleDisplayName</key><string>Couch</string>
  <key>CFBundleIdentifier</key><string>com.abiodun.couch</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>Couch</string>
  <key>CFBundleIconFile</key><string>Couch</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>Remote for Google TV</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.abiodun.couch</string>
    <key>CFBundleURLSchemes</key><array><string>couch</string></array>
  </dict></array>
  <key>NSMicrophoneUsageDescription</key><string>Couch sends your voice to the TV when you hold the voice button.</string>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
# plutil escapes the paths, so a folder name with & or < cannot break the plist.
plutil -insert CouchProjectPath -string "$PROJECT" "$APP/Contents/Info.plist"
plutil -insert CouchUVPath -string "$UV" "$APP/Contents/Info.plist"

codesign --force --deep -s - "$APP" >/dev/null
echo "Built $APP"
