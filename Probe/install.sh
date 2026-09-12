#!/usr/bin/env bash
# Build RegiProbe and install it at a stable path.
#
# The stable path is not cosmetic. TCC keys an Accessibility grant on the
# binary's code designated requirement; for an ad-hoc-signed binary that
# degenerates to path + cdhash, so launching from DerivedData means a new grant
# on every rebuild and a trail of dead entries in System Settings.
#
# Ad-hoc signing still re-prompts on each rebuild. To make the grant survive,
# create a self-signed code-signing certificate once (Keychain Access >
# Certificate Assistant > Create a Certificate, type "Code Signing") and pass
# its name:
#
#   ./Probe/install.sh "RegiProbeSelfSigned"
#
# Then the DR is anchored to that leaf and the grant persists across rebuilds.

set -euo pipefail
cd "$(dirname "$0")/.."

IDENTITY="${1:--}"
DEST="/Applications/RegiProbe.app"

echo "Building…"
xcodebuild -project Probe/RegiProbe.xcodeproj -scheme RegiProbe \
    -configuration Release -destination 'platform=macOS' \
    CODE_SIGN_IDENTITY="$IDENTITY" build >/dev/null

BUILT=$(xcodebuild -project Probe/RegiProbe.xcodeproj -scheme RegiProbe \
    -configuration Release -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}')/RegiProbe.app

echo "Installing to $DEST…"
rm -rf "$DEST"
ditto "$BUILT" "$DEST"
codesign --force --deep --sign "$IDENTITY" --options runtime "$DEST"

echo
echo "Installed. Designated requirement:"
codesign -d --requirements - "$DEST" 2>&1 | sed 's/^/  /'
echo
if [ "$IDENTITY" = "-" ]; then
    echo "NOTE: ad-hoc signed, so the Accessibility grant will not survive a rebuild."
    echo "      Pass a self-signed identity name to fix that (see the header)."
fi
echo "Next: launch it, press 'Grant Accessibility…', approve, and confirm the"
echo "      'Event tap' row turns green. If Settings shows it enabled but the row"
echo "      stays red, the signature changed — re-grant, or use a stable identity."
