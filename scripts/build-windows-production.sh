#!/bin/bash
# Windows Production Build Script

set -e

echo "Building LocalWrap for Windows production..."

# Load production environment variables
if [ -f .env.windows.production ]; then
    export $(cat .env.windows.production | grep -v '^#' | xargs)
fi

# Build with code signing
npm run dist:win

echo "Windows production build complete!"
echo "Check the dist/ directory for the signed installer."
