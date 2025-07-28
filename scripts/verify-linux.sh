#!/bin/bash
# Linux Verification Script

set -e

echo "Verifying Linux AppImage signature..."

# Check if AppImage exists
if [ ! -f "dist/LocalWrap-*.AppImage" ]; then
    echo "Error: LocalWrap AppImage not found in dist/ directory"
    exit 1
fi

# Check AppImage integrity
./dist/LocalWrap-*.AppImage --appimage-extract-and-run --help > /dev/null

# Verify GPG signature if .asc file exists
if [ -f "dist/LocalWrap-*.AppImage.asc" ]; then
    gpg --verify dist/LocalWrap-*.AppImage.asc
else
    echo "Warning: No GPG signature file found"
fi

echo "Linux verification complete!"
