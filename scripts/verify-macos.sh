#!/bin/bash
# macOS Verification Script

set -e

echo "Verifying macOS app signature..."

# Check if app exists (try both possible locations)
if [ -d "dist/LocalWrap.app" ]; then
    APP_PATH="dist/LocalWrap.app"
elif [ -d "dist/mac-arm64/LocalWrap.app" ]; then
    APP_PATH="dist/mac-arm64/LocalWrap.app"
else
    echo "Error: LocalWrap.app not found in dist/ directory"
    exit 1
fi

# Verify code signature
codesign --verify --verbose --deep --strict "$APP_PATH"

# Check entitlements
codesign --display --entitlements - "$APP_PATH"

echo "macOS verification complete!"
