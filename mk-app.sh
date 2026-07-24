#!/bin/sh
# Compile Bubo.app into the directory given as $1. Shared by build.sh (local
# install) and pack.sh (DMG). Runs --selftest unless BUBO_NO_SELFTEST is set,
# so a headless/CI pack can skip the sensor checks.
set -e
cd "$(dirname "$0")"
APP="${1:?usage: mk-app.sh <dest-app-path>}"
OBJ="$(mktemp -d)"
trap 'rm -rf "$OBJ"' EXIT

# Version comes from the git tag, so a release can't ship a bundle that reports
# the previous version. Override with BUBO_VERSION; falls back to 0.0 outside
# a tagged checkout.
VERSION="${BUBO_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
VERSION="${VERSION:-0.0}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp assets/Bubo.icns "$APP/Contents/Resources/"

# vendored sensor layer (MacMonitor, MIT — see sensors/README.md)
clang -fobjc-arc -O2 -c -Isensors -o "$OBJ/IOReportWrapper.o" sensors/IOReportWrapper.m
clang -O2 -c -Isensors -o "$OBJ/SMC.o" sensors/SMC.c

# -lIOReport: private, ships only inside the dyld shared cache (no file on disk)
swiftc -O -parse-as-library \
  -import-objc-header sensors/Bridge.h \
  -o "$APP/Contents/MacOS/Bubo" \
  Bubo.swift Sensors.swift Logo.swift "$OBJ/IOReportWrapper.o" "$OBJ/SMC.o" \
  -framework IOKit -lIOReport

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Bubo</string>
  <key>CFBundleExecutable</key><string>Bubo</string>
  <key>CFBundleIconFile</key><string>Bubo</string>
  <key>CFBundleIdentifier</key><string>local.bubo</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign -s - --force "$APP"
[ -n "$BUBO_NO_SELFTEST" ] || "$APP/Contents/MacOS/Bubo" --selftest
