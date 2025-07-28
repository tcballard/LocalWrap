# LocalWrap - Secure Desktop Wrapper for Development Servers

A secure, cross-platform desktop application that wraps localhost development servers with modern security practices, system tray integration, and a professional desktop experience.

## 🔒 Security Features

- **Context Isolation**: Renderer processes are isolated from Node.js
- **Sandbox Mode**: Renderer runs in a restricted sandbox environment  
- **Content Security Policy**: Strict CSP headers prevent XSS attacks
- **Request Rate Limiting**: API endpoints are protected against abuse
- **Input Validation**: All inputs are validated and sanitized
- **Secure Static Serving**: Files served with security headers and restrictions
- **Single Instance**: Prevents multiple app instances for security
- **URL Validation**: Only localhost URLs are allowed

## 🚀 Quick Start

### 1. Prerequisites
- **Node.js 18+** (Download from [nodejs.org](https://nodejs.org/))
- **npm** (comes with Node.js)
- **Git** (optional, for cloning)

### 2. Setup Project
\`\`\`bash
# Create project directory
mkdir localwrap
cd localwrap

# Initialize npm project
npm init -y

# Install secure dependencies
npm install electron@^32.0.0 express@^4.19.2 helmet@^7.1.0 express-rate-limit@^7.2.0 validator@^13.12.0 --save
npm install electron-builder@^25.0.0 --save-dev
\`\`\`

### 3. Project Structure
Create this secure folder structure:
\`\`\`
localwrap/
├── package.json           # Project configuration
├── main.js               # Secure Electron main process
├── preload.js            # Secure IPC bridge
├── public/               # Your web files (served securely)
│   ├── index.html       # Optional custom pages
│   ├── style.css        # Stylesheets
│   └── app.js           # Client-side JavaScript
├── assets/              # App icons and resources
│   ├── icon.png         # 256x256 app icon
│   ├── icon.ico         # Windows icon
│   ├── icon.icns        # macOS icon
│   └── tray-icon.png    # 16x16 or 32x32 tray icon
└── dist/                # Built distributables (auto-generated)
\`\`\`

### 4. Create Icons (Recommended)
- **app icon**: \`assets/icon.png\` (256x256 pixels)
- **tray icon**: \`assets/tray-icon.png\` (16x16 or 32x32 pixels)
- **Windows**: \`assets/icon.ico\` (multi-size)
- **macOS**: \`assets/icon.icns\` (multi-size)

### 5. Development Commands
\`\`\`bash
# Start in development mode (with DevTools)
npm run dev

# Start in production mode  
npm start

# Check security configuration
npm run security-check

# Build distributable for current platform
npm run dist
\`\`\`

## ✨ Key Features

### 🖥️ **Desktop Integration**
- Native Windows/macOS/Linux application
- System tray minimization with context menu
- Professional window management and controls
- Single instance enforcement

### 🛡️ **Security First**
- Modern Electron security practices (v32+)
- Content Security Policy (CSP) protection
- Request rate limiting and validation
- Sandbox mode for renderer processes
- Context isolation between main/renderer
- Secure static file serving

### 🚀 **Development Ready**
- Express.js server with security middleware
- Hot reload friendly (refresh to see changes)
- API endpoints with validation
- CORS protection and security headers
- Built-in health and status monitoring

### 📦 **Distribution Ready**
- Cross-platform builds (Windows/macOS/Linux)
- Code signing support (configure certificates)
- Auto-updater ready architecture
- Professional installer generation

## 🔧 Customization Guide

### Adding Your Web Application
1. Place your HTML, CSS, JS files in the \`public/\` directory
2. The server automatically serves them with security headers
3. Main page loads from \`http://localhost:3000\`
4. Custom routes can be added to the Express server

### Creating Secure API Endpoints
Add routes to \`main.js\` in the \`createServer()\` function:
\`\`\`javascript
// Add after existing API routes
expressApp.get('/api/custom', (req, res) => {
  // Input validation
  const { param } = req.query;
  if (!validator.isAlphanumeric(param || '')) {
    return res.status(400).json({ error: 'Invalid parameter' });
  }
  
  res.json({ 
    message: 'Custom endpoint response',
    param: param 
  });
});
\`\`\`

### Configuring Server Settings
Modify these constants in \`main.js\`:
\`\`\`javascript
const SERVER_PORT = 3000;        // Change port
const SERVER_HOST = 'localhost'; // Keep as localhost for security
\`\`\`

### Customizing Security Policies
Update CSP headers in the \`helmet\` configuration:
\`\`\`javascript
contentSecurityPolicy: {
  directives: {
    defaultSrc: ["'self'"],
    // Add your custom directives here
  }
}
\`\`\`

## 🎛️ System Tray Features

- **Minimize to Tray**: Close window to minimize instead of quit
- **Right-click Menu**: Access app controls and information
- **Double-click**: Show/hide main window
- **Status Display**: Shows server running status
- **Quick Actions**: Open in browser, about dialog, quit

## 📦 Building for Distribution

### Development Build
\`\`\`bash
npm run build          # Build for current platform
\`\`\`

### Production Builds
\`\`\`bash
# Windows (from any platform)
npx electron-builder --win

# macOS (requires macOS)
npx electron-builder --mac

# Linux
npx electron-builder --linux
\`\`\`

### Code Signing (Production)
1. **Windows**: Obtain a code signing certificate and configure in \`package.json\`
2. **macOS**: Set up Apple Developer account and certificates
3. **Linux**: AppImage format doesn't require signing

## 🔍 Security Best Practices

### For Developers
- Keep dependencies updated: \`npm audit\` and \`npm update\`
- Review any new dependencies for security issues
- Don't disable security features without understanding implications
- Use HTTPS for any external API calls from your web app
- Validate all user inputs in both client and server code

### For Distribution
- Enable code signing for production builds
- Set up auto-updater for security patches
- Use environment variables for sensitive configuration
- Audit your web application code for security vulnerabilities
- Test the app on clean systems before distribution

## 🛠️ Troubleshooting

### Common Issues
**Port already in use**: Change \`SERVER_PORT\` in \`main.js\`
**Window won't show**: Delete app data folder and restart
**Build fails**: Run \`npm install\` to ensure all dependencies
**Tray icon missing**: Add icon files to \`assets/\` folder
**Security warnings**: Check CSP configuration in browser DevTools

### Development Debugging
- Use \`npm run dev\` to open DevTools automatically
- Check console for security policy violations
- Monitor network tab for failed requests
- Use \`npm run security-check\` to validate configuration

### Performance Optimization
- Minimize files in \`public/\` directory
- Use compression for large assets
- Implement caching strategies for API responses
- Consider lazy loading for heavy components

## 📊 Monitoring and Maintenance

### Built-in Monitoring
- \`/api/health\` - Server health and uptime
- \`/api/status\` - Application status and version
- System tray shows running status
- Console logging for errors and security events

### Log Files
- Main process logs: Check terminal/console output
- Renderer logs: Available in DevTools console
- Server logs: Express middleware logging

## 🤝 Contributing

LocalWrap follows secure development practices:
1. All dependencies are kept up-to-date
2. Security vulnerabilities are addressed promptly  
3. Code changes are reviewed for security implications
4. New features maintain security standards

## 📄 License

MIT License - Feel free to use, modify, and distribute

---

**LocalWrap** - Bringing localhost to your desktop, securely. 🔒

*Built with modern Electron security practices and designed for professional development workflows.*
