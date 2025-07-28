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
