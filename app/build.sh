#!/bin/bash
# Build the app bundle:  app/build.sh [--dev] [--arch arm64|x86_64]
#   --dev   the test identity from identity.json: its own bundle id, name,
#           folders and socket, no hotkeys, no microphone
#
# A bundle (rather than a bare binary) is what gives the app a stable TCC identity
# for Screen Recording / Microphone — a raw swiftc binary would inherit the
# grant of whatever terminal launched it, which is exactly the coupling this app
# exists to remove.
#
# Deliberately no signing / notarization: single-user local phase.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
KIND=prod
ARCH=arm64
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) KIND=dev ;;
    --arch) shift; ARCH="${1:-}" ;;
    *) echo "usage: app/build.sh [--dev] [--arch arm64|x86_64]" >&2; exit 64 ;;
  esac
  shift
done
case "$ARCH" in arm64|x86_64) ;; *) echo "build.sh: --arch takes arm64 or x86_64" >&2; exit 64 ;; esac
IDENTITY="$HERE/identity.sh"
NAME="$("$IDENTITY" get "$KIND" name)"
EXECUTABLE="$("$IDENTITY" get "$KIND" executable)"
SHA="$(git -C "$REPO" rev-parse --short HEAD)"
[[ -z "$(git -C "$REPO" status --porcelain -- app cmd)" ]] || SHA="$SHA-dirty"
APP="$HERE/build/$NAME.app"
GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT
"$IDENTITY" swift > "$GEN/IdentityTable.swift"

# Developer ID, not ad-hoc. TCC keys a grant to the code-signing identity, so an
# ad-hoc signature (whose identity changes every build) makes macOS treat each
# rebuild as a brand-new app and forget every permission. A real signing identity
# plus a frozen bundle id is what makes a grant stick.
SIGN_ID="${WINDOWCLIP_SIGN_ID:-Developer ID Application: Joel Brubaker (UQ27DB7N8K)}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
"$IDENTITY" plist "$KIND" "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist" "$SHA"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# --- Deployment target ----------------------------------------------------
# macOS 15 (Sequoia) is the floor, and it must be stated EXPLICITLY on every
# swiftc invocation in this project. swiftc with no -target bakes the *build
# machine's* OS version in as the binary's minimum, silently — which shipped an
# app declaring LSMinimumSystemVersion 14.0 around an embedded recorder that
# refused to load below macOS 26. It launches fine on the build machine and
# dies with a dyld error in the second user's hands.
#
# 15 rather than 14 because the recorder renders its background with SwiftUI
# MeshGradient (Sequoia+) and has no #available fallback for the API's absence.
#
# The recorder and CLI helpers are built by `pnpm run build:*` in package.json,
# which carries the same flag — JSON can't hold a comment, so the reasoning
# lives here. Keep the two in sync; `otool -l <bin> | grep -A4 LC_BUILD_VERSION`
# is how you check what actually got baked in.
swiftc -O \
  -target "$ARCH-apple-macosx15.0" \
  "$HERE"/Sources/*.swift "$GEN/IdentityTable.swift" \
  -o "$APP/Contents/MacOS/$EXECUTABLE"

# --- App icon -------------------------------------------------------------
# icon-master.png is the source art inset to the macOS icon grid (824 of 1024,
# centred). The source is a full-bleed iOS icon; dropped in as-is it renders
# visibly larger than every neighbouring Dock icon, because macOS expects the
# artwork to sit inside a margin rather than fill the tile.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$HERE/Resources/icon-master.png" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$HERE/Resources/icon-master.png" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# --- Embedded helpers -----------------------------------------------------
# The app carries its own recorder and background art so it can live in
# /Applications and keep working — it must not reach back into a checkout that
# may be moved or deleted. Falls back to the repo copies for dev builds.
# The tracked recorder is arm64; another arch compiles its own from source.
if [[ $ARCH != arm64 ]]; then
  swiftc -O -target "$ARCH-apple-macosx15.0" "$REPO"/cmd/recorder/*.swift -o "$APP/Contents/MacOS/recorder"
elif [[ -x "$REPO/cmd/recorder/recorder" ]]; then
  cp "$REPO/cmd/recorder/recorder" "$APP/Contents/MacOS/recorder"
fi
if [[ -f "$REPO/assets/big-sur-graphic.jpg" ]]; then
  cp "$REPO/assets/big-sur-graphic.jpg" "$APP/Contents/Resources/big-sur-graphic.jpg"
fi

# --- Signing --------------------------------------------------------------
# Inside out: nested code must be signed before the bundle that contains it, or
# the outer signature seals over unsigned code and fails validation.
#
# --options runtime (hardened runtime) is required for notarization later. It
# also gates microphone access behind an entitlement, hence the entitlements
# file on BOTH binaries.
ENTS="$HERE/Resources/Windowclip.entitlements"
SIGN_FLAGS=(--force --options runtime --timestamp --entitlements "$ENTS" --sign "$SIGN_ID")

if [[ -f "$APP/Contents/MacOS/recorder" ]]; then
  codesign "${SIGN_FLAGS[@]}" "$APP/Contents/MacOS/recorder"
fi
codesign "${SIGN_FLAGS[@]}" "$APP"

codesign --verify --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
echo "built $APP"
