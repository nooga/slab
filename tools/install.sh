#!/bin/bash
# Install Slab from GitHub Releases into /Applications (~/Applications if
# that isn't writable).
#
#   curl -fsSL https://github.com/nooga/slab/releases/latest/download/install.sh | bash
#
# The app is signed ad hoc, not notarized. Files fetched by curl carry no
# quarantine flag, so Gatekeeper lets it open without the
# Privacy & Security dance a browser download needs.
#
# SLAB_VERSION=0.0.2 picks a release (default: the latest);
# SLAB_INSTALL_DIR picks the folder.

set -euo pipefail

REPO="nooga/slab"
ASSET="Slab.zip"
VERSION="${SLAB_VERSION:-}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "Slab runs on Apple Silicon Macs only." >&2
    exit 1
fi

if [[ -n "${SLAB_INSTALL_DIR:-}" ]]; then
    DEST="$SLAB_INSTALL_DIR"
elif [[ -w /Applications ]]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
fi
mkdir -p "$DEST"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

if [[ -n "$VERSION" ]]; then
    URL="https://github.com/$REPO/releases/download/v$VERSION/$ASSET"
else
    URL="https://github.com/$REPO/releases/latest/download/$ASSET"
fi

echo "Downloading Slab${VERSION:+ $VERSION}…"
if ! curl -fsSL "$URL" -o "$TMP/$ASSET"; then
    echo "Couldn't download $URL" >&2
    exit 1
fi

ditto -x -k "$TMP/$ASSET" "$TMP/unpacked"
if [[ ! -d "$TMP/unpacked/Slab.app" ]]; then
    echo "The download has no Slab.app in it." >&2
    exit 1
fi

if pgrep -f "Slab.app/Contents/MacOS/slab" >/dev/null; then
    echo "Quitting the running Slab…"
    osascript -e 'quit app "Slab"' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "Slab.app/Contents/MacOS/slab" >/dev/null || break
        sleep 1
    done
fi

rm -rf "$DEST/Slab.app"
ditto "$TMP/unpacked/Slab.app" "$DEST/Slab.app"
xattr -dr com.apple.quarantine "$DEST/Slab.app" 2>/dev/null || true
# Claim .slab projects now rather than when Finder first notices the app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST/Slab.app" || true

V=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$DEST/Slab.app/Contents/Info.plist" 2>/dev/null || echo "?")
echo "Installed Slab $V in $DEST."
echo "Open it with: open \"$DEST/Slab.app\""
