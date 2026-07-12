#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${LOCALWRAP_VERSION:?LOCALWRAP_VERSION is required}"
BUILD_ROOT="${LOCALWRAP_RELEASE_DIR:-$ROOT/.build/LocalWrapMac-Unsigned}"
ARCHIVE="$BUILD_ROOT/LocalWrap.xcarchive"
APP="$ARCHIVE/Products/Applications/LocalWrap.app"
DMG="$BUILD_ROOT/LocalWrap-$VERSION-universal.dmg"
CHECKSUM="$DMG.sha256"

mkdir -p "$BUILD_ROOT"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
xcodebuild archive -project "$ROOT/LocalWrap.xcodeproj" -scheme LocalWrapMac \
  -configuration Release -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=

[[ -d "$APP" ]] || { echo "error: archive did not contain LocalWrap.app" >&2; exit 1; }
codesign --verify --deep --strict --verbose=2 "$APP"
lipo "$APP/Contents/MacOS/LocalWrap" -verify_arch arm64 x86_64

STAGE="$BUILD_ROOT/dmg-root"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/LocalWrap.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname LocalWrap -srcfolder "$STAGE" -format UDZO -ov "$DMG"
shasum -a 256 "$DMG" | awk '{print $1}' >"$CHECKSUM"

echo "Unsigned (ad-hoc signed), unnotarized pre-release: $DMG"
echo "SHA-256: $(cat "$CHECKSUM")"
