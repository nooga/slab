#!/bin/bash
# Package Slab as a macOS app: zig-out/Slab.app; with --dmg also
# zig-out/Slab-<version>.dmg, with --zip also zig-out/Slab.zip (what
# tools/install.sh downloads).
#
#   tools/package_app.sh [--dmg] [--zip]
#
# The bundle carries the factory files (machines, kernels, packs, pack
# tools, demos, splash and logo) in Contents/Resources; slab chdirs there
# when it runs from a .app (main.zig enterBundleResources). Homebrew's
# raylib is copied into Contents/Frameworks so the app runs without it.
# Signed ad hoc with the JIT entitlements in tools/app/entitlements.plist.

set -euo pipefail

cd "$(dirname "$0")/.."

NAME="Slab"
APP="zig-out/$NAME.app"
VERSION=$(sed -n 's/^ *\.version = "\(.*\)",/\1/p' build.zig.zon)
DMG=0
ZIP=0
for a in "$@"; do
    case "$a" in
        --dmg) DMG=1 ;;
        --zip) ZIP=1 ;;
        *) echo "usage: tools/package_app.sh [--dmg] [--zip]" >&2; exit 2 ;;
    esac
done

echo "building slab $VERSION (ReleaseFast)"
zig build -Doptimize=ReleaseFast --prefix zig-out/release

echo "assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp zig-out/release/bin/slab "$APP/Contents/MacOS/slab"
sed "s/@VERSION@/$VERSION/g" tools/app/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Factory files, as a dev build sees them from the repo root.
RES="$APP/Contents/Resources"
for d in machines kernels packs demos; do
    [[ -d $d ]] && rsync -a --exclude '.DS_Store' "$d" "$RES/"
done
mkdir -p "$RES/tools"
rsync -a --exclude '.DS_Store' --exclude '__pycache__' tools/library "$RES/tools/"
cp splash.png slab.png "$RES/"
# The licenses travel with the binary (COPYING.md §Source for the app).
mkdir -p "$RES/Licenses"
cp LICENSE NOTICE COPYING.md "$RES/Licenses/"
cp LICENSES/*.txt "$RES/Licenses/"

# Icon.
ICONSET=$(mktemp -d)/icon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s tools/app/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) tools/app/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/icon.icns"
rm -rf "$(dirname "$ICONSET")"

# Embed every non-system dylib (raylib) and point the binary at the copy.
BIN="$APP/Contents/MacOS/slab"
for lib in $(otool -L "$BIN" | awk 'NR > 1 { print $1 }' | grep -v -E '^(/System/|/usr/lib/)'); do
    base=$(basename "$lib")
    cp -L "$lib" "$APP/Contents/Frameworks/$base"
    chmod u+w "$APP/Contents/Frameworks/$base"
    install_name_tool -id "@rpath/$base" "$APP/Contents/Frameworks/$base"
    install_name_tool -change "$lib" "@executable_path/../Frameworks/$base" "$BIN"
done
if otool -L "$BIN" "$APP"/Contents/Frameworks/*.dylib | grep -q /opt/homebrew; then
    echo "error: the bundle still links homebrew:" >&2
    otool -L "$BIN" "$APP"/Contents/Frameworks/*.dylib | grep /opt/homebrew >&2
    exit 1
fi

echo "signing (ad hoc)"
for f in "$APP"/Contents/Frameworks/*.dylib; do
    codesign -s - --force --options runtime "$f"
done
codesign -s - --force --options runtime --entitlements tools/app/entitlements.plist "$APP"
codesign --verify --deep --strict "$APP"

echo "$APP: $(du -sh "$APP" | cut -f1)"

if [[ $DMG == 1 ]]; then
    # The window is a Slab faceplate (tools/app/make_dmg_background.py),
    # laid out by dmgbuild, which writes Finder's .DS_Store itself: no
    # Finder scripting, so it runs headless.
    VENV=zig-out/.dmgbuild
    if [[ ! -x $VENV/bin/dmgbuild ]]; then
        python3 -m venv "$VENV"
        "$VENV/bin/pip" install -q dmgbuild
    fi
    OUT="zig-out/$NAME-$VERSION.dmg"
    BG=zig-out/dmg-background.tiff
    tiffutil -cathidpicheck tools/app/dmg-background.png tools/app/dmg-background@2x.png -out "$BG" 2>/dev/null
    rm -f "$OUT"
    "$VENV/bin/dmgbuild" -s tools/app/dmg_settings.py \
        -D app="$APP" -D background="$BG" -D icon="$RES/icon.icns" \
        "$NAME $VERSION" "$OUT" >/dev/null
    echo "$OUT: $(du -sh "$OUT" | cut -f1)"
fi

if [[ $ZIP == 1 ]]; then
    OUT="zig-out/$NAME.zip"
    rm -f "$OUT"
    ditto -c -k --keepParent "$APP" "$OUT"
    echo "$OUT: $(du -sh "$OUT" | cut -f1)"
fi
