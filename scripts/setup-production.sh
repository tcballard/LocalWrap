#!/bin/bash

# LocalWrap Production Certificate Setup Script
# This script guides you through setting up production certificates

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

# Function to detect OS
detect_os() {
    case "$(uname -s)" in
        Darwin*)    echo "macos";;
        Linux*)     echo "linux";;
        CYGWIN*|MINGW*|MSYS*) echo "windows";;
        *)          echo "unknown";;
    esac
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to setup macOS production certificates
setup_macos_production() {
    print_status "Setting up macOS production certificates..."
    
    # Check for Xcode
    if ! command_exists xcode-select; then
        print_error "Xcode command line tools not found. Please install Xcode first."
        exit 1
    fi
    
    # Check for existing certificates
    print_status "Checking for existing certificates..."
    CERT_COUNT=$(security find-identity -v -p codesigning | grep -c "valid identities found" || echo "0")
    
    if [ "$CERT_COUNT" -gt 0 ]; then
        print_success "Found existing certificates:"
        security find-identity -v -p codesigning
    else
        print_warning "No code signing certificates found"
        print_status "You need to set up certificates in Xcode:"
        print_status "1. Open Xcode"
        print_status "2. Go to Xcode → Preferences → Accounts"
        print_status "3. Add your Apple ID"
        print_status "4. Click 'Manage Certificates'"
        print_status "5. Click '+' and select 'Developer ID Application'"
        
        read -p "Press Enter when you've completed the certificate setup..."
    fi
    
    # Create production environment file
    print_status "Creating production environment file..."
    
    cat > .env.macos.production << EOF
# macOS Production Code Signing Configuration
# Uncomment and configure these values for production builds

# Enable automatic certificate discovery
CSC_IDENTITY_AUTO_DISCOVERY=true

# For App Store distribution (uncomment if distributing via App Store)
# APPLE_ID=your-apple-id@example.com
# APPLE_ID_PASS=your-app-specific-password

# For notarization (uncomment for direct distribution)
# NOTARIZE=true

# For Developer ID Application signing (recommended for direct distribution)
# This will use the first available Developer ID Application certificate
EOF
    
    print_success "macOS production configuration created"
    print_status "Edit .env.macos.production with your Apple ID and app-specific password"
}

# Function to setup Windows production certificates
setup_windows_production() {
    print_status "Setting up Windows production certificates..."
    
    print_warning "Windows certificates must be purchased from a trusted CA"
    print_status "Recommended providers:"
    print_status "- DigiCert: https://www.digicert.com"
    print_status "- Sectigo: https://www.sectigo.com"
    print_status "- GlobalSign: https://www.globalsign.com"
    
    # Create certificates directory
    mkdir -p certificates
    
    # Create production environment file
    print_status "Creating production environment file..."
    
    cat > .env.windows.production << EOF
# Windows Production Code Signing Configuration
# Uncomment and configure these values for production builds

# Certificate file path (relative to project root)
# CSC_LINK=./certificates/your-certificate.pfx

# Certificate password
# CSC_KEY_PASSWORD=your-certificate-password

# Timestamp servers
CSC_TIMESTAMP_SERVER=http://timestamp.digicert.com
CSC_RFC3161_TIMESTAMP_SERVER=http://timestamp.digicert.com

# Additional options
CSC_TRIPLET=true
EOF
    
    print_success "Windows production configuration created"
    print_status "1. Purchase a code signing certificate"
    print_status "2. Place the .pfx file in the certificates/ directory"
    print_status "3. Edit .env.windows.production with your certificate details"
}

# Function to setup Linux production certificates
setup_linux_production() {
    print_status "Setting up Linux production certificates..."
    
    if ! command_exists gpg; then
        print_error "GPG not found. Please install GPG first."
        print_status "Ubuntu/Debian: sudo apt-get install gnupg"
        print_status "CentOS/RHEL: sudo yum install gnupg"
        exit 1
    fi
    
    # Check for existing GPG keys
    print_status "Checking for existing GPG keys..."
    if gpg --list-secret-keys --keyid-format LONG | grep -q "sec"; then
        print_success "Found existing GPG keys:"
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
    
    # Get GPG key ID
    print_status "Getting GPG key ID..."
    GPG_KEY_ID=$(gpg --list-secret-keys --keyid-format LONG | grep "sec" | head -1 | awk '{print $2}' | cut -d'/' -f2)
    
    if [ -n "$GPG_KEY_ID" ]; then
        print_success "Using GPG key ID: $GPG_KEY_ID"
    else
        print_warning "Could not determine GPG key ID automatically"
        print_status "Please run: gpg --list-secret-keys --keyid-format LONG"
        print_status "And note the key ID (the part after the slash)"
    fi
    
    # Create production environment file
    print_status "Creating production environment file..."
    
    cat > .env.linux.production << EOF
# Linux Production Code Signing Configuration
# Uncomment and configure these values for production builds

# GPG key ID for signing
# GPG_KEY_ID=$GPG_KEY_ID

# AppImage signing
APPIMAGE_SIGN=true

# Additional options
# GPG_PASSPHRASE=your-gpg-passphrase
EOF
    
    print_success "Linux production configuration created"
    print_status "Edit .env.linux.production with your GPG key ID"
}

# Function to create production build scripts
create_production_scripts() {
    print_status "Creating production build scripts..."
    
    # Create production build script for macOS
    cat > scripts/build-macos-production.sh << 'EOF'
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
EOF
    
    # Create production build script for Windows
    cat > scripts/build-windows-production.sh << 'EOF'
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
EOF
    
    # Create production build script for Linux
    cat > scripts/build-linux-production.sh << 'EOF'
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
EOF
    
    # Make scripts executable
    chmod +x scripts/build-*-production.sh
    
    print_success "Production build scripts created"
}

# Function to create GitHub Actions secrets guide
create_github_secrets_guide() {
    print_status "Creating GitHub Actions secrets guide..."
    
    cat > GITHUB_SECRETS_SETUP.md << 'EOF'
# GitHub Actions Secrets Setup

To enable automated code signing in GitHub Actions, you need to configure the following secrets:

## Required Secrets

### macOS Secrets
- `MACOS_CERTIFICATE`: Base64-encoded .p12 certificate file
- `MACOS_CERTIFICATE_PASSWORD`: Password for the certificate
- `APPLE_ID`: Your Apple ID email
- `APPLE_ID_PASS`: App-specific password for your Apple ID

### Windows Secrets
- `WINDOWS_CERTIFICATE`: Base64-encoded .pfx certificate file
- `WINDOWS_CERTIFICATE_PASSWORD`: Password for the certificate

### Linux Secrets
- `LINUX_GPG_KEY`: Your GPG private key (export with `gpg --export-secret-key`)
- `LINUX_GPG_KEY_ID`: Your GPG key ID

## How to Set Up Secrets

1. Go to your GitHub repository
2. Click **Settings** → **Secrets and variables** → **Actions**
3. Click **New repository secret**
4. Add each secret with the appropriate name and value

## How to Export Certificates

### macOS Certificate
```bash
# Export certificate to base64
base64 -i certificate.p12 | pbcopy
```

### Windows Certificate
```bash
# Export certificate to base64
base64 -i certificate.pfx | clip
```

### Linux GPG Key
```bash
# Export GPG key
gpg --export-secret-key YOUR_KEY_ID | base64 | pbcopy
```

## Security Notes
- Never commit these secrets to your repository
- Rotate secrets regularly
- Use app-specific passwords for Apple ID
- Store certificates securely
EOF
    
    print_success "GitHub Actions secrets guide created"
}

# Main function
main() {
    print_status "LocalWrap Production Certificate Setup"
    print_status "======================================="
    
    OS=$(detect_os)
    print_status "Detected OS: $OS"
    
    # Setup certificates for current platform
    case $OS in
        "macos")
            setup_macos_production
            ;;
        "windows")
            setup_windows_production
            ;;
        "linux")
            setup_linux_production
            ;;
        *)
            print_error "Unsupported operating system: $OS"
            exit 1
            ;;
    esac
    
    # Setup for all platforms
    setup_windows_production
    setup_linux_production
    
    create_production_scripts
    create_github_secrets_guide
    
    print_success "Production certificate setup complete!"
    print_status ""
    print_status "Next steps:"
    print_status "1. Configure your certificates (see PRODUCTION_SETUP.md)"
    print_status "2. Edit the .env.*.production files with your details"
    print_status "3. Test production builds with scripts/build-*-production.sh"
    print_status "4. Set up GitHub Actions secrets (see GITHUB_SECRETS_SETUP.md)"
    print_status ""
    print_status "For detailed instructions, see PRODUCTION_SETUP.md"
}

# Run main function
main "$@" 