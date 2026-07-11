#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${LOCALWRAP_VERSION:-3.3.0}"
BUILD_ROOT="${LOCALWRAP_RELEASE_DIR:-$ROOT/.build/LocalWrapMac-Signed}"
ARCHIVE="$BUILD_ROOT/LocalWrap.xcarchive"
APP="$ARCHIVE/Products/Applications/LocalWrap.app"
DMG="$BUILD_ROOT/LocalWrap-$VERSION-universal.dmg"
CHECKSUM="$DMG.sha256"
IDENTITY="${LOCALWRAP_DEVELOPER_ID_APPLICATION:-}"
NOTARY_PROFILE="${LOCALWRAP_NOTARY_PROFILE:-}"

die() { echo "error: $*" >&2; exit 1; }
[[ -n "$IDENTITY" ]] || die "LOCALWRAP_DEVELOPER_ID_APPLICATION is required"
security find-identity -v -p codesigning | grep -Fq "Developer ID Application: $IDENTITY" \
  || die "Developer ID Application identity is not installed: $IDENTITY"
if [[ -z "$NOTARY_PROFILE" ]]; then
  [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]] \
    || die "set LOCALWRAP_NOTARY_PROFILE or APPLE_ID, APPLE_TEAM_ID, and APPLE_APP_SPECIFIC_PASSWORD"
fi

mkdir -p "$BUILD_ROOT"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
xcodebuild archive -project "$ROOT/LocalWrap.xcodeproj" -scheme LocalWrapMac \
  -configuration Release -destination 'generic/platform=macOS' -archivePath "$ARCHIVE" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application: $IDENTITY" DEVELOPMENT_TEAM="${APPLE_TEAM_ID:-}"

[[ -d "$APP" ]] || die "archive did not contain LocalWrap.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements :- "$APP" >"$BUILD_ROOT/entitlements.plist"
! /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' \
  "$BUILD_ROOT/entitlements.plist" >/dev/null 2>&1 || die "Release enables get-task-allow"
lipo "$APP/Contents/MacOS/LocalWrap" -verify_arch arm64 x86_64

STAGE="$BUILD_ROOT/dmg-root"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/LocalWrap.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname LocalWrap -srcfolder "$STAGE" -format UDZO -ov "$DMG"
codesign --force --sign "Developer ID Application: $IDENTITY" --timestamp "$DMG"

if [[ -n "$NOTARY_PROFILE" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
else
  xcrun notarytool submit "$DMG" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" --wait
fi
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
shasum -a 256 "$DMG" | awk '{print $1}' >"$CHECKSUM"
echo "Signed, notarized, and verified: $DMG"
echo "SHA-256: $(cat "$CHECKSUM")"
