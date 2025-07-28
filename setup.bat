@echo off
setlocal enabledelayedexpansion

echo ========================================
echo     LocalWrap - Secure Setup
echo ========================================
echo.
echo Setting up secure desktop wrapper for
echo localhost development servers...
echo.

REM Check if Node.js is installed
echo [1/6] Checking Node.js installation...
node --version >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo ❌ ERROR: Node.js is not installed!
    echo.
    echo Please install Node.js 18+ from https://nodejs.org/
    echo LocalWrap requires Node.js for secure operation.
    echo.
    pause
    exit /b 1
)

echo ✅ Node.js found:
node --version
echo.

REM Check Node.js version (basic check)
for /f "tokens=1" %%a in ('node --version') do set NODE_VERSION=%%a
echo Node.js version: %NODE_VERSION%

REM Check if npm is available
echo [2/6] Checking npm availability...
npm --version >nul 2>&1
if %errorlevel% neq 0 (
    echo ❌ ERROR: npm is not available!
    echo Please reinstall Node.js with npm included.
    pause
    exit /b 1
)

echo ✅ npm found:
npm --version
echo.

REM Create secure project structure
echo [3/6] Creating secure project structure...
if not exist "public" (
    mkdir public
    echo ✅ Created public/ directory
)
if not exist "assets" (
    mkdir assets
    echo ✅ Created assets/ directory
)

echo.

REM Install secure dependencies
echo [4/6] Installing secure dependencies...
echo This may take a few minutes depending on your connection...
echo.

echo Installing Electron and core dependencies...
call npm install electron@^32.0.0 --save
if %errorlevel% neq 0 (
    echo ❌ ERROR: Failed to install Electron!
    echo Please check your internet connection and try again.
    pause
    exit /b 1
)

echo Installing Express server with security middleware...
call npm install express@^4.19.2 helmet@^7.1.0 express-rate-limit@^7.2.0 validator@^13.12.0 --save
if %errorlevel% neq 0 (
    echo ❌ ERROR: Failed to install server dependencies!
    pause
    exit /b 1
)

echo Installing build tools...
call npm install electron-builder@^25.0.0 --save-dev
if %errorlevel% neq 0 (
    echo ❌ ERROR: Failed to install build dependencies!
    pause
    exit /b 1
)

echo ✅ All dependencies installed successfully!
echo.

REM Run security audit
echo [5/6] Running security audit...
call npm audit --audit-level=moderate
if %errorlevel% equ 0 (
    echo ✅ Security audit passed - no high-risk vulnerabilities found
) else (
    echo ⚠️  Security audit found some issues - consider running 'npm audit fix'
)
echo.

REM Create convenience scripts
echo [6/6] Creating convenience scripts...

REM Create start script
(
echo @echo off
echo echo Starting LocalWrap...
echo echo.
echo echo 🔒 LocalWrap - Secure Development Server
echo echo ========================================
echo echo.
echo npm start
echo.
echo if errorlevel 1 ^(
echo     echo.
echo     echo ❌ LocalWrap failed to start!
echo     echo Check the console output above for details.
echo     echo.
echo     pause
echo ^)
) > start-localwrap.bat

echo ✅ Created start-localwrap.bat

REM Create development script
(
echo @echo off
echo echo Starting LocalWrap in Development Mode...
echo echo.
echo echo 🔧 Development Mode - DevTools Enabled
echo echo ========================================
echo echo.
echo npm run dev
echo.
echo if errorlevel 1 ^(
echo     echo.
echo     echo ❌ LocalWrap development mode failed to start!
echo     echo Check the console output above for details.
echo     echo.
echo     pause
echo ^)
) > dev-localwrap.bat

echo ✅ Created dev-localwrap.bat

REM Create build script
(
echo @echo off
echo echo Building LocalWrap for distribution...
echo echo.
echo echo 📦 Building distributable package
echo echo ================================
echo echo.
echo npm run dist
echo.
echo if errorlevel 0 ^(
echo     echo.
echo     echo ✅ Build completed successfully!
echo     echo Check the dist/ folder for your distributable files.
echo     echo.
echo ^) else ^(
echo     echo.
echo     echo ❌ Build failed!
echo     echo Check the console output above for details.
echo     echo.
echo ^)
echo pause
) > build-localwrap.bat

echo ✅ Created build-localwrap.bat

REM Create security check script
(
echo @echo off
echo echo Running LocalWrap Security Check...
echo echo.
echo echo 🛡️  Security Verification
echo echo =======================
echo echo.
echo echo Checking for vulnerabilities...
echo npm audit
echo.
echo echo Checking package versions...
echo npm outdated
echo.
echo echo Security check completed.
echo pause
) > security-check.bat

echo ✅ Created security-check.bat

REM Create project documentation
echo Creating project documentation...
(
echo # LocalWrap Project
echo.
echo Your secure LocalWrap installation is complete!
echo.
echo ## 📂 Project Structure
echo.
echo ```
echo localwrap/
echo ├── package.json              ^(project configuration^)
echo ├── main.js                   ^(secure Electron main process^)
echo ├── preload.js                ^(secure IPC bridge^)
echo ├── public/                   ^(your web files^)
echo │   └── app.html              ^(sample custom page^)
echo ├── assets/                   ^(app icons^)
echo │   ├── icon.png              ^(256x256 app icon^)
echo │   ├── icon.ico              ^(Windows icon^)
echo │   ├── icon.icns             ^(macOS icon^)
echo │   └── tray-icon.png         ^(16x16 tray icon^)
echo └── dist/                     ^(built packages^)
echo ```
echo.
echo ## 🚀 Quick Start Commands
echo.
echo - **Start LocalWrap**: Double-click `start-localwrap.bat`
echo - **Development Mode**: Double-click `dev-localwrap.bat`
echo - **Build Package**: Double-click `build-localwrap.bat`
echo - **Security Check**: Double-click `security-check.bat`
echo.
echo ## 📋 Manual Commands
echo.
echo ```bash
echo npm start          # Start the app
echo npm run dev        # Development mode with DevTools
echo npm run dist       # Build distributable package
echo npm run security-check  # Check for security issues
echo ```
echo.
echo ## 🔒 Security Features
echo.
echo - Context isolation enabled
echo - Content Security Policy ^(CSP^) headers
echo - Request rate limiting
echo - Input validation and sanitization
echo - Secure static file serving
echo - Single instance enforcement
echo.
echo ## 📝 Next Steps
echo.
echo 1. **Add Icons** ^(optional^): Place icon files in the `assets/` folder
echo 2. **Customize**: Add your web files to the `public/` folder
echo 3. **Run**: Double-click `start-localwrap.bat` to launch
echo 4. **Develop**: Use `dev-localwrap.bat` for development with DevTools
echo 5. **Distribute**: Use `build-localwrap.bat` to create installers
echo.
echo ## 🛡️ Security Best Practices
echo.
echo - Keep dependencies updated with `npm update`
echo - Run security audits regularly with `security-check.bat`
echo - Use HTTPS for external API calls
echo - Validate all user inputs
echo - Review code changes for security implications
echo.
echo ## 📞 Support
echo.
echo - Check the setup instructions in the README
echo - Review the security documentation
echo - Use DevTools ^(F12^) for debugging
echo - Monitor the console for security warnings
echo.
echo ---
echo **LocalWrap** - Secure localhost development, wrapped for desktop 🔒
) > README-SETUP.md

echo ✅ Created README-SETUP.md

REM Create a simple icon placeholder instruction
(
echo # Icon Setup Instructions
echo.
echo To make your LocalWrap app look professional, add these icon files:
echo.
echo ## Required Icons:
echo.
echo 1. **App Icon**: `assets/icon.png` ^(256x256 pixels^)
echo    - Main application icon shown in taskbar and windows
echo.
echo 2. **Tray Icon**: `assets/tray-icon.png` ^(16x16 or 32x32 pixels^)
echo    - Small icon shown in system tray
echo.
echo ## Platform-Specific Icons ^(Optional^):
echo.
echo 3. **Windows**: `assets/icon.ico` ^(multi-size .ico file^)
echo 4. **macOS**: `assets/icon.icns` ^(multi-size .icns file^)
echo.
echo ## Creating Icons:
echo.
echo - Use any image editor ^(GIMP, Photoshop, etc.^)
echo - Start with a high-resolution image ^(512x512 or larger^)
echo - Keep designs simple and recognizable at small sizes
echo - Use transparency for modern appearance
echo.
echo ## Online Icon Tools:
echo.
echo - favicon.io - Generate icons from text or images
echo - iconifier.net - Convert PNG to ICO/ICNS
echo - app-icon-generator.com - Generate all sizes at once
echo.
echo LocalWrap will work without custom icons, but they make your app look more professional!
) > ICON-SETUP.md

echo ✅ Created ICON-SETUP.md

echo.
echo ========================================
echo        Setup Complete! 🎉
echo ========================================
echo.
echo ✅ LocalWrap has been set up successfully!
echo.
echo 🔒 SECURITY FEATURES ENABLED:
echo    • Context isolation and sandboxing
echo    • Content Security Policy headers
echo    • Request rate limiting
echo    • Input validation
echo    • Secure static file serving
echo.
echo 🚀 QUICK START OPTIONS:
echo    1. Double-click 'start-localwrap.bat' to run the app
echo    2. Double-click 'dev-localwrap.bat' for development mode
echo    3. Run 'npm start' from command line
echo.
echo 📁 CUSTOMIZATION:
echo    • Add your web files to the 'public' folder
echo    • Add app icons to the 'assets' folder
echo    • See README-SETUP.md for detailed instructions
echo.
echo 🛡️ SECURITY:
echo    • Run 'security-check.bat' periodically
echo    • Keep dependencies updated with 'npm update'
echo    • Review ICON-SETUP.md for professional icons
echo.
echo Your LocalWrap server will run on http://localhost:3000
echo and appear in your system tray for easy access.
echo.
echo Happy coding! 💻
echo.
pause
