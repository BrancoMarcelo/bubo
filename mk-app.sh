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

# Build one architecture, chosen by BUBO_ARCH (default: the host). The local dev
# loop stays a single native slice; pack.sh sets BUBO_ARCH to ship a separate
# .dmg per arch. On Apple Silicon the full sensor layer works; on Intel the
# private IOReport/SMC channels this code reads don't exist, so those panels read
# zero and hide — CPU/RAM/apps/battery/network/disk still work.
ARCH="${BUBO_ARCH:-$(uname -m)}"

# vendored sensor layer (MacMonitor, MIT — see sensors/README.md)
clang -arch "$ARCH" -fobjc-arc -O2 -c -Isensors -o "$OBJ/IOReportWrapper.o" sensors/IOReportWrapper.m
clang -arch "$ARCH" -O2 -c -Isensors -o "$OBJ/SMC.o" sensors/SMC.c

# -lIOReport is private (dyld shared cache, no file on disk). Cross-compiling the
# non-host arch has no stub to link against, so allow dynamic_lookup there.
XLINK=""
[ "$ARCH" = "$(uname -m)" ] || XLINK="-Xlinker -undefined -Xlinker dynamic_lookup"

swiftc -O -parse-as-library -target "$ARCH-apple-macos13" \
  -import-objc-header sensors/Bridge.h \
  -o "$APP/Contents/MacOS/Bubo" \
  Bubo.swift Sensors.swift Logo.swift "$OBJ/IOReportWrapper.o" "$OBJ/SMC.o" \
  -framework IOKit -lIOReport $XLINK

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
# selftest only makes sense for a native build — a cross-arch slice can't run here
if [ -z "$BUBO_NO_SELFTEST" ] && [ "$ARCH" = "$(uname -m)" ]; then
  "$APP/Contents/MacOS/Bubo" --selftest
fi
