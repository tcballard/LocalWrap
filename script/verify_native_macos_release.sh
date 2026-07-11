#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/.build/LocalWrapMac-Release"
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT"
xcodebuild -project "$ROOT/LocalWrap.xcodeproj" -scheme LocalWrapMac \
  -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build

APP="$DERIVED/Build/Products/Release/LocalWrap.app"
test -d "$APP"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = com.localwrap.app
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" = 3.3.0
lipo "$APP/Contents/MacOS/LocalWrap" -verify_arch arm64 x86_64
test -f "$APP/Contents/Resources/Credits.rtf"
test -f "$APP/Contents/Resources/icon.icns"
codesign --verify --deep --strict "$APP"
echo "Verified unsigned/ad-hoc universal LocalWrap.app (publication remains disabled)."
