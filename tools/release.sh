#!/bin/bash
# Publish a Slab release on GitHub: package HEAD and attach Slab.zip,
# Slab-<version>.dmg and install.sh to release v<version>, with the
# version from build.zig.zon. Bump that version and commit first.
#
#   tools/release.sh
#
# Builds here, not in CI: fy is a path dependency (../fy). HEAD is checked
# out beside this repo so ../fy resolves the same, and uncommitted work
# stays out of the release.

set -euo pipefail

cd "$(dirname "$0")/.."

REPO="nooga/slab"
VERSION=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon)
TAG="v$VERSION"

if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "$TAG is already released; bump .version in build.zig.zon." >&2
    exit 1
fi

BUILD="$(cd .. && pwd)/.slab-release"
git worktree remove --force "$BUILD" 2>/dev/null || rm -rf "$BUILD"
git worktree add --detach "$BUILD" HEAD
trap 'git worktree remove --force "$BUILD"' EXIT
(cd "$BUILD" && tools/package_app.sh --dmg --zip)
OUT="$BUILD/zig-out"

git tag -a "$TAG" -m "Slab $VERSION" HEAD 2>/dev/null || echo "tag $TAG exists, reusing it"
git push origin "$TAG"

gh release create "$TAG" -R "$REPO" \
    --title "Slab $VERSION" \
    --notes "Apple Silicon, macOS 13 or later.

Install:

    curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash

Or open the DMG and drag Slab to Applications. It is not notarized, so the first launch needs System Settings > Privacy & Security > Open Anyway." \
    "$OUT/Slab.zip" "$OUT/Slab-$VERSION.dmg" tools/install.sh

echo "released $TAG: https://github.com/$REPO/releases/tag/$TAG"
