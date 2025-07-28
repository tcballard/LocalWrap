# Code Signing Setup for LocalWrap

This guide explains how to set up code signing certificates for production distribution of LocalWrap on macOS, Windows, and Linux.

## Overview

Code signing is essential for:
- **macOS**: Bypassing Gatekeeper warnings and enabling notarization
- **Windows**: Avoiding SmartScreen warnings and enabling automatic updates
- **Linux**: Building trust with package managers and users

## Prerequisites

### macOS
1. **Apple Developer Account** ($99/year)
2. **Xcode** installed
3. **Developer ID Application Certificate**

### Windows
1. **Code Signing Certificate** from a trusted CA (e.g., DigiCert, Sectigo)
2. **Certificate file** (.pfx or .p12 format)
3. **Certificate password**

### Linux
1. **GPG key** for signing packages
2. **AppImage signing** (optional but recommended)

## Setup Instructions

### macOS Code Signing

#### 1. Get Apple Developer Certificate
```bash
# Open Keychain Access and request certificate from Apple
# Or use Xcode: Xcode → Preferences → Accounts → Manage Certificates
```

#### 2. Configure for Development
```bash
# For development builds (no certificate needed)
npm run build:mac
```

#### 3. Configure for Production
Update `package.json` build configuration:
```json
"mac": {
    "target": "dmg",
    "icon": "assets/icon.icns",
    "hardenedRuntime": true,
    "entitlements": "assets/entitlements.plist",
    "entitlementsInherit": "assets/entitlements.plist",
    "gatekeeperAssess": false,
    "identity": "Developer ID Application: Your Name (TEAM_ID)"
}
```

#### 4. Build and Sign
```bash
# Build with code signing
npm run dist:mac

# For notarization (required for distribution outside App Store)
# Add to package.json scripts:
"notarize": "electron-notarize --file dist/LocalWrap-*.dmg --bundle-id com.localwrap.app"
```

### Windows Code Signing

#### 1. Obtain Code Signing Certificate
- Purchase from DigiCert, Sectigo, or other trusted CA
- Download certificate file (.pfx or .p12)

#### 2. Configure Certificate
Update `package.json` build configuration:
```json
"win": {
    "target": "nsis",
    "icon": "assets/icon.ico",
    "requestedExecutionLevel": "asInvoker",
    "certificateFile": "path/to/your/certificate.pfx",
    "certificatePassword": "your-certificate-password",
    "rfc3161TimeStampServer": "http://timestamp.digicert.com",
    "timeStampServer": "http://timestamp.digicert.com"
}
```

#### 3. Environment Variables (Recommended)
Set environment variables instead of hardcoding:
```bash
# Windows
set CSC_LINK=path/to/your/certificate.pfx
set CSC_KEY_PASSWORD=your-certificate-password

# macOS/Linux
export CSC_LINK=path/to/your/certificate.pfx
export CSC_KEY_PASSWORD=your-certificate-password
```

#### 4. Build and Sign
```bash
npm run dist:win
```

### Linux Code Signing

#### 1. Generate GPG Key
```bash
# Generate GPG key for signing
gpg --full-generate-key

# Export public key
gpg --export -a "Your Name" > public-key.asc
```

#### 2. Configure AppImage Signing
```bash
# Install appimagetool
wget "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"
chmod +x appimagetool-x86_64.AppImage

# Sign AppImage
./appimagetool-x86_64.AppImage --sign --sign-key YOUR_GPG_KEY_ID dist/LocalWrap-*.AppImage
```

#### 3. Build
```bash
npm run dist:linux
```

## Environment-Specific Configurations

### Development Environment
For development builds without code signing:
```bash
npm run build
```

### Staging Environment
For testing with basic signing:
```bash
# macOS
npm run dist:mac

# Windows
npm run dist:win

# Linux
npm run dist:linux
```

### Production Environment
For production releases with full signing:

#### macOS Production
```bash
# Set environment variables
export CSC_IDENTITY_AUTO_DISCOVERY=true
export APPLE_ID=your-apple-id@example.com
export APPLE_ID_PASS=your-app-specific-password

# Build and notarize
npm run dist:mac
npm run notarize
```

#### Windows Production
```bash
# Set certificate environment variables
set CSC_LINK=path/to/production/certificate.pfx
set CSC_KEY_PASSWORD=production-password

# Build
npm run dist:win
```

#### Linux Production
```bash
# Sign with production GPG key
gpg --sign --detach-sign --armor dist/LocalWrap-*.AppImage
```

## Security Best Practices

### Certificate Management
1. **Store certificates securely** - Use environment variables or secure key storage
2. **Rotate certificates regularly** - Plan for certificate renewal
3. **Limit access** - Only authorized developers should have access to signing certificates
4. **Backup certificates** - Keep secure backups of all certificates

### Build Security
1. **Use CI/CD** - Automate signing in secure build environments
2. **Verify signatures** - Always verify signatures before distribution
3. **Monitor expiration** - Set up alerts for certificate expiration
4. **Audit builds** - Log all signed builds for audit purposes

## Troubleshooting

### macOS Issues
```bash
# Check certificate validity
security find-identity -v -p codesigning

# Verify app signature
codesign --verify --verbose --deep --strict dist/LocalWrap.app

# Check notarization status
xcrun altool --notarization-info [UUID] -u [APPLE_ID]
```

### Windows Issues
```bash
# Verify signature
signtool verify /pa dist/LocalWrap-Setup.exe

# Check certificate details
certmgr -list -c -s -r localMachine
```

### Linux Issues
```bash
# Verify GPG signature
gpg --verify LocalWrap-*.AppImage.asc

# Check AppImage integrity
./LocalWrap-*.AppImage --appimage-extract-and-run --help
```

## Continuous Integration

### GitHub Actions Example
```yaml
name: Build and Sign
on: [push, pull_request]

jobs:
  build:
    runs-on: ${{ matrix.os }}
    strategy:
      matrix:
        os: [macos-latest, windows-latest, ubuntu-latest]
    
    steps:
    - uses: actions/checkout@v3
    
    - name: Setup Node.js
      uses: actions/setup-node@v3
      with:
        node-version: '18'
        
    - name: Install dependencies
      run: npm ci
      
    - name: Build and sign
      env:
        CSC_LINK: ${{ secrets.CSC_LINK }}
        CSC_KEY_PASSWORD: ${{ secrets.CSC_KEY_PASSWORD }}
        APPLE_ID: ${{ secrets.APPLE_ID }}
        APPLE_ID_PASS: ${{ secrets.APPLE_ID_PASS }}
      run: npm run dist
```

## Distribution

### macOS
- **App Store**: Submit through App Store Connect
- **Direct Distribution**: Upload signed DMG to website
- **Homebrew**: Create cask for easy installation

### Windows
- **Microsoft Store**: Submit through Partner Center
- **Direct Distribution**: Upload signed installer to website
- **Chocolatey**: Create package for easy installation

### Linux
- **AppImage**: Distribute directly
- **Snap**: Submit to Snap Store
- **Flatpak**: Submit to Flathub
- **Package Managers**: Create packages for major distributions

## Resources

- [Electron Builder Code Signing](https://www.electron.build/code-signing)
- [Apple Developer Code Signing](https://developer.apple.com/support/code-signing/)
- [Microsoft Code Signing](https://docs.microsoft.com/en-us/windows/msix/package/create-certificate-package-signing)
- [Linux AppImage Signing](https://docs.appimage.org/packaging-guide/overview.html#code-signing) 