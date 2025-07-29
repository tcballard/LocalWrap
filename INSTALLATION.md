# LocalWrap Installation Guide

LocalWrap is a desktop development server that lets you run scripts and create desktop apps from localhost servers.

## Windows Installation

### Option 1: Installer (Recommended)
1. Download `LocalWrap-Setup-1.0.0.exe` from the releases page
2. Run the installer - Windows Defender may show a warning (click "More info" → "Run anyway")
3. Follow the installation wizard
4. LocalWrap will be installed to `C:\Users\{username}\AppData\Local\Programs\LocalWrap\`
5. Desktop and Start Menu shortcuts will be created automatically

### Option 2: Portable Version
1. Download `LocalWrap-Portable-1.0.0.exe` 
2. Run directly - no installation required
3. All settings are stored in the same folder as the executable

## First Launch

1. **Launch LocalWrap** from desktop shortcut or Start Menu
2. **Select a project folder** using the "Browse" button
3. **Enter a script command** (e.g., `npm start`, `python -m http.server 3001`)
4. **Choose a port** (LocalWrap runs on port 3000, so use 3001+ for your projects)
5. **Click "Run Script"** to start your development server
6. **Click "Desktop App"** to create a standalone desktop application

## Troubleshooting

### Windows Defender Warning
- Windows may show "Windows protected your PC" - this is normal for unsigned apps
- Click "More info" → "Run anyway" to proceed with installation

### Firewall Warnings
- Windows Firewall may ask for network access - click "Allow" 
- This is needed for localhost development servers

### Script Execution Issues
- Ensure Node.js, Python, or other required tools are installed and in your PATH
- Try running the script in Command Prompt first to verify it works

### Port Conflicts
- If you get port errors, LocalWrap will automatically suggest alternative ports
- Common ports: 3001, 8000, 8080, 5000

## Uninstallation

1. Go to **Settings → Apps & Features**
2. Find **LocalWrap** in the list
3. Click **Uninstall**
4. Or use the uninstaller in the installation directory

## What LocalWrap Does

LocalWrap creates a bridge between command-line development tools and desktop applications:

1. **Runs your development scripts** in a selected project folder
2. **Monitors the output** in a built-in terminal
3. **Creates desktop apps** that bundle your script + web interface
4. **Handles port management** automatically to avoid conflicts

Perfect for turning web apps, documentation sites, or development servers into standalone desktop applications!

## Support

For issues or questions:
- Check the terminal output for error messages
- Ensure your development tools (Node.js, Python, etc.) are properly installed
- Try running scripts manually first to verify they work