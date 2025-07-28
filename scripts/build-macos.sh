#!/bin/bash
# macOS Build Script

set -e

# Load environment variables
if [ -f .env.macos ]; then
    export $(cat .env.macos | grep -v '^#' | xargs)
fi

echo "Building for macOS..."

# Build the application
npm run dist:mac

echo "macOS build complete!"
echo "Check the dist/ directory for the DMG file."
