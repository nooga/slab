#!/bin/bash
# Publish a Slab release on GitHub: package HEAD and attach Slab.zip,
# Slab-<version>.dmg and install.sh to release v<version>, with the
# version from build.zig.zon, then point the Homebrew cask in
# nooga/homebrew-tap at it. Bump that version and commit first.
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

# The app compiles fy in (../fy). A GPL binary owes its complete source,
# so the fy commit must be on GitHub before the app built from it ships.
FY_DIR="$(cd .. && pwd)/fy"
FY=$(git -C "$FY_DIR" rev-parse HEAD)
git -C "$FY_DIR" fetch -q origin
if [[ -z "$(git -C "$FY_DIR" branch -r --contains "$FY")" ]]; then
    echo "fy $FY isn't on GitHub; push it first (the release's source must be public)." >&2
    exit 1
fi
if [[ -n "$(git -C "$FY_DIR" status --porcelain --untracked-files=no)" ]]; then
    echo "fy has uncommitted changes; commit and push them first." >&2
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
    --notes "Apple Silicon, macOS 13 or later. Built from $TAG with fy [\`${FY:0:7}\`](https://github.com/nooga/fy/commit/$FY); those two are the complete source (GPL-3.0-or-later, see COPYING.md).

Install:

    curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash

Or with Homebrew: \`brew install --cask nooga/tap/slab\`

Or open the DMG and drag Slab to Applications. It is not notarized, so the first launch needs System Settings > Privacy & Security > Open Anyway." \
    "$OUT/Slab.zip" "$OUT/Slab-$VERSION.dmg" tools/install.sh

echo "released $TAG: https://github.com/$REPO/releases/tag/$TAG"

# The Homebrew cask in nooga/homebrew-tap: brew install nooga/tap/slab.
SHA=$(shasum -a 256 "$OUT/Slab.zip" | cut -d' ' -f1)
TAP=$(mktemp -d)
gh repo clone nooga/homebrew-tap "$TAP" -- -q
mkdir -p "$TAP/Casks"
sed -e "s/@VERSION@/$VERSION/" -e "s/@SHA256@/$SHA/" tools/app/slab.rb.in > "$TAP/Casks/slab.rb"
git -C "$TAP" add Casks/slab.rb
git -C "$TAP" commit -q -m "Update slab to $TAG"
git -C "$TAP" push -q
rm -rf "$TAP"
echo "cask: nooga/homebrew-tap Casks/slab.rb at $VERSION"
