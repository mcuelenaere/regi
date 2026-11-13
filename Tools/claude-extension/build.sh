#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Package Regi's MCP relay as a Claude Desktop extension: Regi.mcpb, next to
# this script. Double-click it to install.
#
#   Tools/claude-extension/build.sh [path/to/Regi.app]
#
# Without an argument it takes the Debug build from DerivedData. The extension
# carries its own copy of the app's signed regi-mcp, the relay to the app's
# socket, so it keeps working wherever Regi.app lives. It doesn't need Regi
# running: until it is, Claude sees the tools Regi last offered and calls say to
# open Regi.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

app=${1:-}
if [ -z "$app" ]; then
    products=$(xcodebuild -project "$repo/Regi.xcodeproj" -scheme Regi -configuration Debug -showBuildSettings 2>/dev/null |
        awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')
    app="$products/Regi.app"
fi
relay="$app/Contents/MacOS/regi-mcp"
[ -x "$relay" ] || { echo "no regi-mcp in $app: build Regi first" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/server"
cp "$relay" "$stage/server/regi-mcp"
cp "$repo/App/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" "$stage/icon.png"
sed "s/__VERSION__/$version/" "$here/manifest.json" > "$stage/manifest.json"

# An .mcpb is a zip with manifest.json at its root. Plain zip keeps the
# relay's executable bit and its code signature.
out="$here/Regi.mcpb"
rm -f "$out"
(cd "$stage" && zip -q -r -X "$out" manifest.json icon.png server)
echo "$out (Regi $version)"
