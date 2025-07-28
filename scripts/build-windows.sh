#!/bin/bash
# Windows Build Script

set -e

# Load environment variables
if [ -f .env.windows ]; then
    export $(cat .env.windows | grep -v '^#' | xargs)
fi

echo "Building for Windows..."

# Build the application
npm run dist:win

echo "Windows build complete!"
echo "Check the dist/ directory for the installer."
