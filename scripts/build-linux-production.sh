#!/bin/bash
# Linux Production Build Script

set -e

echo "Building LocalWrap for Linux production..."

# Load production environment variables
if [ -f .env.linux.production ]; then
    export $(cat .env.linux.production | grep -v '^#' | xargs)
fi

# Build with code signing
npm run dist:linux

# Sign AppImage if configured
if [ "$APPIMAGE_SIGN" = "true" ] && [ -n "$GPG_KEY_ID" ]; then
    echo "Signing AppImage..."
    ./scripts/appimagetool-x86_64.AppImage --sign --sign-key "$GPG_KEY_ID" dist/LocalWrap-*.AppImage
fi

echo "Linux production build complete!"
echo "Check the dist/ directory for the signed AppImage file."
