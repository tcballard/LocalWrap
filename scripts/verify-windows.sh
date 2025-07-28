#!/bin/bash
# Windows Verification Script

set -e

echo "Verifying Windows installer signature..."

# Check if installer exists
if [ ! -f "dist/LocalWrap-Setup.exe" ]; then
    echo "Error: LocalWrap-Setup.exe not found in dist/ directory"
    exit 1
fi

# Verify signature (requires Windows or Wine)
if command -v signtool >/dev/null 2>&1; then
    signtool verify /pa dist/LocalWrap-Setup.exe
else
    echo "Warning: signtool not found. Please verify signature on Windows."
fi

echo "Windows verification complete!"
