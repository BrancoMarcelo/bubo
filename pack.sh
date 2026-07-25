#!/bin/sh
# Build two drag-to-install DMGs — one per arch — so the download page and the
# Homebrew cask can offer the right one. Each is the .app + an Applications
# shortcut.
set -e
cd "$(dirname "$0")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# arch:label — label names the .dmg the way a human picks it
for pair in arm64:apple-silicon x86_64:intel; do
  arch="${pair%:*}"; label="${pair#*:}"
  rm -rf "$STAGE"/*
  BUBO_ARCH="$arch" sh mk-app.sh "$STAGE/Bubo.app"
  ln -s /Applications "$STAGE/Applications"      # drag target inside the window

  DMG="Bubo-$label.dmg"
  rm -f "$DMG"
  hdiutil create -volname Bubo -srcfolder "$STAGE" -ov -format ULFO "$DMG" >/dev/null
  echo "packed: $DMG"
done

echo
echo "Both are ad-hoc signed, not notarized. On a Mac they weren't built on,"
echo "Gatekeeper blocks first launch. Fix once, after dragging to /Applications:"
echo "  xattr -dr com.apple.quarantine /Applications/Bubo.app"
