#!/bin/bash
# Linux Build Script

set -e

# Load environment variables
if [ -f .env.linux ]; then
    export $(cat .env.linux | grep -v '^#' | xargs)
fi

echo "Building for Linux..."

# Build the application
npm run dist:linux

# Sign AppImage if configured
if [ "$APPIMAGE_SIGN" = "true" ] && [ -n "$GPG_KEY_ID" ]; then
    echo "Signing AppImage..."
    ./scripts/appimagetool-x86_64.AppImage --sign --sign-key "$GPG_KEY_ID" dist/LocalWrap-*.AppImage
fi

echo "Linux build complete!"
echo "Check the dist/ directory for the AppImage file."
