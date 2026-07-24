#!/bin/sh
# build + install Bubo.app into ~/Applications (local dev loop)
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/Bubo.app"
sh mk-app.sh "$APP"
echo "installed: $APP    (open it, or: open '$APP')"
