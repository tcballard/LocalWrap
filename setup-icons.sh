#!/bin/bash

# LocalWrap Icon Setup Script
echo "🎨 Setting up LocalWrap app icons..."

# Check if icon.png exists
if [ ! -f "assets/icon.png" ]; then
    echo "❌ Please save your PNG icon as 'assets/icon.png' first"
    echo "   Then run this script again."
    exit 1
fi

echo "✅ Found icon.png, creating icon formats..."

# Create macOS iconset
echo "📱 Creating macOS icon..."
mkdir -p assets/icon.iconset

# Generate different sizes
sips -z 16 16     assets/icon.png --out assets/icon.iconset/icon_16x16.png
sips -z 32 32     assets/icon.png --out assets/icon.iconset/icon_16x16@2x.png
sips -z 32 32     assets/icon.png --out assets/icon.iconset/icon_32x32.png
sips -z 64 64     assets/icon.png --out assets/icon.iconset/icon_32x32@2x.png
sips -z 128 128   assets/icon.png --out assets/icon.iconset/icon_128x128.png
sips -z 256 256   assets/icon.png --out assets/icon.iconset/icon_128x128@2x.png
sips -z 256 256   assets/icon.png --out assets/icon.iconset/icon_256x256.png
sips -z 512 512   assets/icon.png --out assets/icon.iconset/icon_256x256@2x.png
sips -z 512 512   assets/icon.png --out assets/icon.iconset/icon_512x512.png
sips -z 1024 1024 assets/icon.png --out assets/icon.iconset/icon_512x512@2x.png

# Convert to .icns
iconutil -c icns assets/icon.iconset -o assets/icon.icns

# Clean up iconset
rm -rf assets/icon.iconset

# Create Linux icon
echo "🐧 Creating Linux icon..."
sips -z 512 512 assets/icon.png --out assets/icon-512.png

echo "✅ Icon setup complete!"
echo ""
echo "📁 Created files:"
echo "   - assets/icon.icns (macOS)"
echo "   - assets/icon-512.png (Linux)"
echo ""
echo "⚠️  For Windows (.ico), you'll need to:"
echo "   1. Use an online converter (like convertio.co)"
echo "   2. Or install ImageMagick and run:"
echo "      convert assets/icon.png -define icon:auto-resize=256,128,64,48,32,16 assets/icon.ico"
echo ""
echo "🎯 Your LocalWrap app will now use these icons in the taskbar!" 