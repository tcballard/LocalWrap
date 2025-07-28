#!/bin/bash

# LocalWrap Certificate Setup Script
# This script helps set up code signing certificates for production distribution

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to detect OS
detect_os() {
    case "$(uname -s)" in
        Darwin*)    echo "macos";;
        Linux*)     echo "linux";;
        CYGWIN*|MINGW*|MSYS*) echo "windows";;
        *)          echo "unknown";;
    esac
}

# Function to setup macOS certificates
setup_macos() {
    print_status "Setting up macOS code signing certificates..."
    
    if ! command_exists xcode-select; then
        print_error "Xcode command line tools not found. Please install Xcode first."
        exit 1
    fi
    
    print_status "Checking for existing certificates..."
    
    # Check for Developer ID Application certificate
    if security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
        print_success "Developer ID Application certificate found"
    else
        print_warning "Developer ID Application certificate not found"
        print_status "You need to:"
        print_status "1. Open Xcode"
        print_status "2. Go to Xcode → Preferences → Accounts"
        print_status "3. Select your Apple ID"
        print_status "4. Click 'Manage Certificates'"
        print_status "5. Click '+' and select 'Developer ID Application'"
    fi
    
    # Check for Apple Distribution certificate
    if security find-identity -v -p codesigning | grep -q "Apple Distribution"; then
        print_success "Apple Distribution certificate found"
    else
        print_warning "Apple Distribution certificate not found"
        print_status "This is needed for App Store distribution"
    fi
    
    print_status "Setting up environment variables..."
    
    # Create .env file for certificate configuration
    cat > .env.macos << EOF
# macOS Code Signing Configuration
# Uncomment and set these values for production builds

# For Developer ID Application signing
# CSC_IDENTITY_AUTO_DISCOVERY=true

# For App Store distribution
# APPLE_ID=your-apple-id@example.com
# APPLE_ID_PASS=your-app-specific-password

# For notarization
# NOTARIZE=true
EOF
    
    print_success "macOS certificate setup complete"
    print_status "Edit .env.macos to configure your certificates"
}

# Function to setup Windows certificates
setup_windows() {
    print_status "Setting up Windows code signing certificates..."
    
    print_warning "Windows certificates must be purchased from a trusted CA"
    print_status "Recommended providers:"
    print_status "- DigiCert"
    print_status "- Sectigo"
    print_status "- GlobalSign"
    print_status "- Comodo"
    
    print_status "Setting up environment variables..."
    
    # Create .env file for certificate configuration
    cat > .env.windows << EOF
# Windows Code Signing Configuration
# Uncomment and set these values for production builds

# Certificate file path (relative to project root)
# CSC_LINK=./certificates/your-certificate.pfx

# Certificate password
# CSC_KEY_PASSWORD=your-certificate-password

# Timestamp servers
# CSC_TIMESTAMP_SERVER=http://timestamp.digicert.com
# CSC_RFC3161_TIMESTAMP_SERVER=http://timestamp.digicert.com
EOF
    
    print_success "Windows certificate setup complete"
    print_status "Edit .env.windows to configure your certificates"
}

# Function to setup Linux certificates
setup_linux() {
    print_status "Setting up Linux code signing certificates..."
    
    if ! command_exists gpg; then
        print_error "GPG not found. Please install GPG first."
        print_status "Ubuntu/Debian: sudo apt-get install gnupg"
        print_status "CentOS/RHEL: sudo yum install gnupg"
        exit 1
    fi
    
    print_status "Checking for existing GPG keys..."
    
    # Check if user has GPG keys
    if gpg --list-secret-keys --keyid-format LONG | grep -q "sec"; then
        print_success "GPG keys found"
        gpg --list-secret-keys --keyid-format LONG
    else
        print_warning "No GPG keys found"
        print_status "Would you like to generate a new GPG key? (y/n)"
        read -r response
        if [[ "$response" =~ ^[Yy]$ ]]; then
            print_status "Generating new GPG key..."
            gpg --full-generate-key
            print_success "GPG key generated"
        fi
    fi
    
    print_status "Setting up AppImage signing..."
    
    # Download appimagetool if not present
    if [ ! -f "scripts/appimagetool-x86_64.AppImage" ]; then
        print_status "Downloading appimagetool..."
        mkdir -p scripts
        wget -O scripts/appimagetool-x86_64.AppImage \
            "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
        chmod +x scripts/appimagetool-x86_64.AppImage
        print_success "appimagetool downloaded"
    fi
    
    print_status "Setting up environment variables..."
    
    # Create .env file for certificate configuration
    cat > .env.linux << EOF
# Linux Code Signing Configuration
# Uncomment and set these values for production builds

# GPG key ID for signing
# GPG_KEY_ID=your-gpg-key-id

# AppImage signing
# APPIMAGE_SIGN=true
EOF
    
    print_success "Linux certificate setup complete"
    print_status "Edit .env.linux to configure your certificates"
}

# Function to create build scripts
create_build_scripts() {
    print_status "Creating build scripts..."
    
    # Create scripts directory
    mkdir -p scripts
    
    # Create macOS build script
    cat > scripts/build-macos.sh << 'EOF'
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
EOF
    
    # Create Windows build script
    cat > scripts/build-windows.sh << 'EOF'
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
EOF
    
    # Create Linux build script
    cat > scripts/build-linux.sh << 'EOF'
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
EOF
    
    # Make scripts executable
    chmod +x scripts/build-*.sh
    
    print_success "Build scripts created"
}

# Function to create verification scripts
create_verification_scripts() {
    print_status "Creating verification scripts..."
    
    # Create verification script for macOS
    cat > scripts/verify-macos.sh << 'EOF'
#!/bin/bash
# macOS Verification Script

set -e

echo "Verifying macOS app signature..."

# Check if app exists
if [ ! -d "dist/LocalWrap.app" ]; then
    echo "Error: LocalWrap.app not found in dist/ directory"
    exit 1
fi

# Verify code signature
codesign --verify --verbose --deep --strict dist/LocalWrap.app

# Check entitlements
codesign --display --entitlements - dist/LocalWrap.app

echo "macOS verification complete!"
EOF
    
    # Create verification script for Windows
    cat > scripts/verify-windows.sh << 'EOF'
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
EOF
    
    # Create verification script for Linux
    cat > scripts/verify-linux.sh << 'EOF'
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
EOF
    
    # Make scripts executable
    chmod +x scripts/verify-*.sh
    
    print_success "Verification scripts created"
}

# Main function
main() {
    print_status "LocalWrap Certificate Setup"
    print_status "=========================="
    
    OS=$(detect_os)
    print_status "Detected OS: $OS"
    
    case $OS in
        "macos")
            setup_macos
            ;;
        "windows")
            setup_windows
            ;;
        "linux")
            setup_linux
            ;;
        *)
            print_error "Unsupported operating system: $OS"
            exit 1
            ;;
    esac
    
    create_build_scripts
    create_verification_scripts
    
    print_success "Certificate setup complete!"
    print_status ""
    print_status "Next steps:"
    print_status "1. Edit the .env.$OS file with your certificate details"
    print_status "2. Run 'npm install' to ensure all dependencies are installed"
    print_status "3. Use 'scripts/build-$OS.sh' to build with code signing"
    print_status "4. Use 'scripts/verify-$OS.sh' to verify signatures"
    print_status ""
    print_status "For detailed instructions, see CODE_SIGNING.md"
}

# Run main function
main "$@" 