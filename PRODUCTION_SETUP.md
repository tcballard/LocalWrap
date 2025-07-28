# Production Certificate Setup Guide

This guide will walk you through setting up code signing certificates for production distribution of LocalWrap.

## 🍎 macOS Production Setup

### Prerequisites
- [ ] Apple Developer Account ($99/year)
- [ ] Xcode installed
- [ ] Valid Apple ID

### Step 1: Apple Developer Account
1. Go to [developer.apple.com](https://developer.apple.com)
2. Click "Enroll" and complete the enrollment process
3. Wait for approval (usually 24-48 hours)

### Step 2: Request Certificates in Xcode
1. Open Xcode
2. Go to **Xcode → Preferences → Accounts**
3. Click the "+" button and add your Apple ID
4. Select your Apple ID and click **"Manage Certificates"**
5. Click the "+" button and select:
   - **Developer ID Application** (for direct distribution)
   - **Apple Distribution** (for App Store)

### Step 3: Configure Environment Variables
Create a `.env.macos` file with your certificate details:

```bash
# macOS Production Code Signing
CSC_IDENTITY_AUTO_DISCOVERY=true

# For App Store distribution
APPLE_ID=your-apple-id@example.com
APPLE_ID_PASS=your-app-specific-password

# For notarization
NOTARIZE=true
```

### Step 4: Generate App-Specific Password
1. Go to [appleid.apple.com](https://appleid.apple.com)
2. Sign in with your Apple ID
3. Go to **Security → App-Specific Passwords**
4. Click **"Generate Password"**
5. Use this password in your `.env.macos` file

## 🪟 Windows Production Setup

### Prerequisites
- [ ] Code Signing Certificate from trusted CA
- [ ] Certificate file (.pfx or .p12 format)
- [ ] Certificate password

### Step 1: Purchase Certificate
Recommended providers:
- **DigiCert** - [digicert.com](https://www.digicert.com)
- **Sectigo** - [sectigo.com](https://www.sectigo.com)
- **GlobalSign** - [globalsign.com](https://www.globalsign.com)

### Step 2: Configure Environment Variables
Create a `.env.windows` file:

```bash
# Windows Production Code Signing
CSC_LINK=./certificates/your-certificate.pfx
CSC_KEY_PASSWORD=your-certificate-password
CSC_TIMESTAMP_SERVER=http://timestamp.digicert.com
CSC_RFC3161_TIMESTAMP_SERVER=http://timestamp.digicert.com
```

### Step 3: Store Certificate Securely
```bash
# Create certificates directory
mkdir certificates

# Move your certificate file here
mv /path/to/your/certificate.pfx certificates/
```

## 🐧 Linux Production Setup

### Step 1: Generate GPG Key
```bash
# Generate a new GPG key
gpg --full-generate-key

# List your keys to get the key ID
gpg --list-secret-keys --keyid-format LONG

# Export your public key
gpg --export -a "Your Name" > public-key.asc
```

### Step 2: Configure Environment Variables
Create a `.env.linux` file:

```bash
# Linux Production Code Signing
GPG_KEY_ID=your-gpg-key-id
APPIMAGE_SIGN=true
```

## 🔧 Production Build Commands

### macOS Production Build
```bash
# Load environment variables
source .env.macos

# Build with code signing
npm run dist:mac

# Verify signature
npm run verify:mac
```

### Windows Production Build
```bash
# Load environment variables
source .env.windows

# Build with code signing
npm run dist:win

# Verify signature
npm run verify:win
```

### Linux Production Build
```bash
# Load environment variables
source .env.linux

# Build with code signing
npm run dist:linux

# Verify signature
npm run verify:linux
```

## 🔐 Security Best Practices

### Certificate Management
1. **Never commit certificates to git**
2. **Use environment variables** instead of hardcoding
3. **Store certificates securely** (password manager, secure storage)
4. **Rotate certificates regularly**
5. **Backup certificates** in multiple secure locations

### CI/CD Security
1. **Use GitHub Secrets** for sensitive data
2. **Limit access** to signing certificates
3. **Audit builds** regularly
4. **Monitor certificate expiration**

## 🚀 Quick Production Checklist

### Before First Production Build
- [ ] Apple Developer Account active
- [ ] Certificates installed and verified
- [ ] Environment files configured
- [ ] App-specific passwords generated
- [ ] Test build completed successfully
- [ ] Signatures verified

### For Each Release
- [ ] Update version in package.json
- [ ] Test build on target platform
- [ ] Verify signatures
- [ ] Test installation
- [ ] Upload to distribution channels

## 🆘 Troubleshooting

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

## 📞 Support Resources

- **Apple Developer Support**: [developer.apple.com/support](https://developer.apple.com/support)
- **Electron Builder Docs**: [electron.build](https://www.electron.build)
- **Code Signing Guide**: See `CODE_SIGNING.md` in this project

---

**Ready to go live with your signed app!** 🎯 