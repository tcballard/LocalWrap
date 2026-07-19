#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.build/LocalWrapMac-Release"
die() { echo "error: $*" >&2; exit 1; }

xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
xcodebuild -project "$ROOT/LocalWrap.xcodeproj" -scheme LocalWrapMac \
  -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build

APP="$DERIVED/Build/Products/Release/LocalWrap.app"
[[ -d "$APP" ]] || die "Release build did not contain LocalWrap.app"

EXPECTED_VERSION="$(
  xcodebuild -project "$ROOT/LocalWrap.xcodeproj" -scheme LocalWrapMac \
    -configuration Release -derivedDataPath "$DERIVED" -showBuildSettings |
    awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / && version == "" { version = $2 } END { print version }'
)"
[[ -n "$EXPECTED_VERSION" ]] || die "Release MARKETING_VERSION could not be resolved"

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" = com.localwrap.app ]] || die "unexpected Release bundle identifier: $BUNDLE_ID"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUNDLE_VERSION" = "$EXPECTED_VERSION" ]] \
  || die "Release bundle version $BUNDLE_VERSION does not match $EXPECTED_VERSION"
lipo "$APP/Contents/MacOS/LocalWrap" -verify_arch arm64 x86_64
[[ -f "$APP/Contents/Resources/Credits.rtf" ]] || die "Release credits are missing"
[[ -f "$APP/Contents/Resources/icon.icns" ]] || die "Release icon is missing"
codesign --verify --deep --strict "$APP"
echo "Verified unsigned/ad-hoc universal LocalWrap.app $BUNDLE_VERSION (publication remains disabled)."
