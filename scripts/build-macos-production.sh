#!/bin/bash
# macOS Production Build Script

set -e

echo "Building LocalWrap for macOS production..."

# Load production environment variables
if [ -f .env.macos.production ]; then
    export $(cat .env.macos.production | grep -v '^#' | xargs)
fi

# Build with code signing
npm run dist:mac

echo "macOS production build complete!"
echo "Check the dist/ directory for the signed DMG file."
