#!/bin/sh
# Build a drag-to-install Bubo.dmg (the .app + an Applications shortcut).
set -e
cd "$(dirname "$0")"
STAGE="$(mktemp -d)"
DMG="Bubo.dmg"
trap 'rm -rf "$STAGE"' EXIT

sh mk-app.sh "$STAGE/Bubo.app"
ln -s /Applications "$STAGE/Applications"      # drag target inside the window

rm -f "$DMG"
hdiutil create -volname Bubo -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null

echo "packed: $DMG    (open it, drag Bubo → Applications)"
echo
echo "It is ad-hoc signed, not notarized. On a Mac it wasn't built on, Gatekeeper"
echo "blocks first launch. Fix once, after dragging to /Applications:"
echo "  xattr -dr com.apple.quarantine /Applications/Bubo.app"
