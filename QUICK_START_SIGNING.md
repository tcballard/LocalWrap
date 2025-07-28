# Quick Start: Code Signing Setup

This guide will get you up and running with code signing in under 5 minutes.

## 🚀 Quick Setup

### 1. Run the Setup Script
```bash
npm run setup-certs
```

This will:
- Detect your operating system
- Create platform-specific configuration files
- Set up build and verification scripts
- Download necessary tools

### 2. Configure Your Certificates

#### For macOS:
1. Open Xcode → Preferences → Accounts
2. Add your Apple ID
3. Click "Manage Certificates"
4. Click "+" and select "Developer ID Application"
5. Edit `.env.macos` and uncomment the relevant lines

#### For Windows:
1. Purchase a code signing certificate from DigiCert, Sectigo, etc.
2. Download your `.pfx` file
3. Edit `.env.windows` and set your certificate path and password

#### For Linux:
1. Generate a GPG key: `gpg --full-generate-key`
2. Note your key ID: `gpg --list-secret-keys --keyid-format LONG`
3. Edit `.env.linux` and set your GPG key ID

### 3. Build with Code Signing

```bash
# macOS
npm run dist:mac

# Windows
npm run dist:win

# Linux
npm run dist:linux
```

### 4. Verify Signatures

```bash
# macOS
npm run verify:mac

# Windows
npm run verify:win

# Linux
npm run verify:linux
```

## 🔧 Environment Variables

The setup script creates these files:

- `.env.macos` - macOS certificate configuration
- `.env.windows` - Windows certificate configuration  
- `.env.linux` - Linux GPG key configuration

**Important**: These files contain sensitive information and are automatically added to `.gitignore`.

## 📋 What's Included

✅ **Entitlements file** for macOS security permissions  
✅ **Build scripts** for each platform  
✅ **Verification scripts** to check signatures  
✅ **GitHub Actions workflow** for automated signing  
✅ **Environment configuration** files  
✅ **Security best practices** documentation  

## 🆘 Need Help?

- **Detailed guide**: See `CODE_SIGNING.md`
- **Troubleshooting**: Check the troubleshooting section in `CODE_SIGNING.md`
- **Security**: Review the security best practices

## 🎯 Next Steps

1. **Test your setup**: Run a build and verify the signature
2. **Set up CI/CD**: Configure GitHub Actions secrets for automated builds
3. **Plan distribution**: Choose your distribution channels (App Store, direct download, etc.)
4. **Monitor certificates**: Set up alerts for certificate expiration

---

**Ready to distribute your app securely!** 🚀 