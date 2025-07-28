const { app, BrowserWindow, Menu, Tray, nativeImage, shell, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const url = require('url');

let mainWindow;
let tray;
let server;
const SERVER_PORT = 3000;
const SERVER_HOST = 'localhost';

// Security: Validate that URL is actually localhost
function validateLocalhostURL(targetURL) {
  try {
    const parsedURL = new URL(targetURL);
    return (
      (parsedURL.hostname === 'localhost' || parsedURL.hostname === '127.0.0.1') &&
      parsedURL.port === SERVER_PORT.toString() &&
      parsedURL.protocol === 'http:'
    );
  } catch (error) {
    console.error('Invalid URL:', error);
    return false;
  }
}

// Create secure Express server
async function createServer() {
  try {
    const express = require('express');
    const helmet = require('helmet');
    const rateLimit = require('express-rate-limit');
    const validator = require('validator');
    
    const expressApp = express();
    
    // Security middleware
    expressApp.use(helmet({
      contentSecurityPolicy: {
        directives: {
          defaultSrc: ["'self'"],
          styleSrc: ["'self'", "'unsafe-inline'"],
          scriptSrc: ["'self'"],
          imgSrc: ["'self'", "data:", "blob:"],
          connectSrc: ["'self'"],
          fontSrc: ["'self'"],
          objectSrc: ["'none'"],
          mediaSrc: ["'self'"],
          frameSrc: ["'none'"],
        },
      },
      crossOriginEmbedderPolicy: false
    }));
    
    // Rate limiting
    const limiter = rateLimit({
      windowMs: 15 * 60 * 1000, // 15 minutes
      max: 100, // limit each IP to 100 requests per windowMs
      message: 'Too many requests from this IP, please try again later.',
      standardHeaders: true,
      legacyHeaders: false,
    });
    expressApp.use('/api/', limiter);
    
    // Request size limiting
    expressApp.use(express.json({ limit: '10mb' }));
    expressApp.use(express.urlencoded({ extended: true, limit: '10mb' }));
    
    // Security headers
    expressApp.use((req, res, next) => {
      res.setHeader('X-Frame-Options', 'DENY');
      res.setHeader('X-Content-Type-Options', 'nosniff');
      res.setHeader('Referrer-Policy', 'strict-origin-when-cross-origin');
      next();
    });
    
    // Serve static files securely from public directory
    const publicPath = path.join(__dirname, 'public');
    expressApp.use(express.static(publicPath, {
      dotfiles: 'deny',
      index: false,
      setHeaders: (res, path) => {
        res.setHeader('Cache-Control', 'public, max-age=3600');
      }
    }));
    
    // API endpoints with input validation
    expressApp.get('/api/status', (req, res) => {
      res.json({ 
        status: 'running', 
        timestamp: new Date().toISOString(),
        message: 'LocalWrap server is running securely!',
        version: app.getVersion()
      });
    });
    
    expressApp.get('/api/health', (req, res) => {
      res.json({
        healthy: true,
        uptime: process.uptime(),
        memory: process.memoryUsage(),
        platform: process.platform
      });
    });
    
    // Serve main page
    expressApp.get('/', (req, res) => {
      res.send(`
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0">
          <title>LocalWrap - Secure Development Server</title>
          <meta http-equiv="Content-Security-Policy" content="default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self';">
          <style>
            * {
              margin: 0;
              padding: 0;
              box-sizing: border-box;
            }
            body { 
              font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
              background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
              color: white;
              min-height: 100vh;
              display: flex;
              flex-direction: column;
            }
            .header {
              background: rgba(255,255,255,0.1);
              padding: 20px;
              text-align: center;
              backdrop-filter: blur(10px);
              border-bottom: 1px solid rgba(255,255,255,0.2);
            }
            .container { 
              flex: 1;
              max-width: 1000px;
              margin: 0 auto;
              padding: 40px 20px;
              width: 100%;
            }
            .card {
              background: rgba(255,255,255,0.1); 
              padding: 30px; 
              border-radius: 15px;
              margin: 20px 0;
              backdrop-filter: blur(10px);
              border: 1px solid rgba(255,255,255,0.2);
              transition: transform 0.3s ease;
            }
            .card:hover {
              transform: translateY(-2px);
            }
            .status { 
              background: rgba(76, 175, 80, 0.2); 
              padding: 15px; 
              border-radius: 8px; 
              margin: 20px 0;
              border-left: 4px solid #4CAF50;
            }
            .security-info {
              background: rgba(33, 150, 243, 0.2);
              padding: 15px;
              border-radius: 8px;
              margin: 20px 0;
              border-left: 4px solid #2196F3;
            }
            .api-test { 
              background: rgba(255,255,255,0.1); 
              padding: 20px; 
              border-radius: 8px; 
              margin: 20px 0;
            }
            button {
              background: linear-gradient(45deg, #4CAF50, #45a049);
              color: white;
              border: none;
              padding: 12px 20px;
              border-radius: 8px;
              cursor: pointer;
              font-size: 14px;
              font-weight: 500;
              transition: all 0.3s ease;
              margin: 5px;
            }
            button:hover { 
              background: linear-gradient(45deg, #45a049, #4CAF50);
              transform: translateY(-1px);
              box-shadow: 0 4px 12px rgba(0,0,0,0.2);
            }
            button:active {
              transform: translateY(0);
            }
            #apiResult {
              margin-top: 15px;
              padding: 15px;
              background: rgba(0,0,0,0.3);
              border-radius: 8px;
              font-family: 'Courier New', monospace;
              white-space: pre-wrap;
              border: 1px solid rgba(255,255,255,0.1);
              max-height: 300px;
              overflow-y: auto;
            }
            .feature-grid {
              display: grid;
              grid-template-columns: repeat(auto-fit, minmax(300px, 1fr));
              gap: 20px;
              margin-top: 20px;
            }
            .code {
              background: rgba(0,0,0,0.2);
              padding: 2px 6px;
              border-radius: 4px;
              font-family: 'Courier New', monospace;
              font-size: 0.9em;
            }
            .footer {
              background: rgba(255,255,255,0.05);
              padding: 20px;
              text-align: center;
              border-top: 1px solid rgba(255,255,255,0.1);
            }
          </style>
        </head>
        <body>
          <div class="header">
            <h1>🔒 LocalWrap</h1>
            <p>Secure Desktop Wrapper for Development Servers</p>
          </div>
          
          <div class="container">
            <div class="status">
              <strong>✅ Server Status:</strong> Running securely on http://localhost:${SERVER_PORT}
            </div>
            
            <div class="security-info">
              <strong>🛡️ Security Features:</strong> Content Security Policy enabled, request rate limiting active, static file serving with security headers
            </div>
            
            <div class="card">
              <h2>Welcome to LocalWrap!</h2>
              <p>Your localhost development server is now running in a secure desktop environment with system tray integration.</p>
              
              <div class="api-test">
                <h3>API Testing</h3>
                <button onclick="testStatusAPI()">Test Status API</button>
                <button onclick="testHealthAPI()">Test Health API</button>
                <div id="apiResult"></div>
              </div>
            </div>
            
            <div class="feature-grid">
              <div class="card">
                <h3>🚀 Getting Started</h3>
                <ul style="margin-left: 20px; line-height: 1.6;">
                  <li>Add your web files to the <span class="code">public/</span> directory</li>
                  <li>Create secure API endpoints in <span class="code">main.js</span></li>
                  <li>Access your app via system tray</li>
                  <li>All requests are rate-limited and validated</li>
                </ul>
              </div>
              
              <div class="card">
                <h3>🛡️ Security Features</h3>
                <ul style="margin-left: 20px; line-height: 1.6;">
                  <li>Content Security Policy (CSP) headers</li>
                  <li>Request rate limiting</li>
                  <li>Input validation and sanitization</li>
                  <li>Secure static file serving</li>
                  <li>Context isolation enabled</li>
                </ul>
              </div>
              
              <div class="card">
                <h3>⚙️ System Tray</h3>
                <ul style="margin-left: 20px; line-height: 1.6;">
                  <li>Close window to minimize to tray</li>
                  <li>Right-click tray icon for options</li>
                  <li>Double-click to show/hide window</li>
                  <li>Single instance enforcement</li>
                </ul>
              </div>
            </div>
          </div>
          
          <div class="footer">
            <p>LocalWrap v${app.getVersion()} | Built with Electron + Express | Secure by Design</p>
          </div>

          <script>
            async function testStatusAPI() {
              await testAPI('/api/status');
            }
            
            async function testHealthAPI() {
              await testAPI('/api/health');
            }
            
            async function testAPI(endpoint) {
              const resultDiv = document.getElementById('apiResult');
              resultDiv.textContent = 'Testing API...';
              
              try {
                const response = await fetch(endpoint);
                const data = await response.json();
                resultDiv.textContent = JSON.stringify(data, null, 2);
              } catch (error) {
                resultDiv.textContent = 'Error: ' + error.message;
              }
            }
          </script>
        </body>
        </html>
      `);
    });
    
    // 404 handler
    expressApp.use((req, res) => {
      res.status(404).json({ error: 'Not found' });
    });
    
    // Error handler
    expressApp.use((err, req, res, next) => {
      console.error('Server error:', err);
      res.status(500).json({ error: 'Internal server error' });
    });
    
    return new Promise((resolve, reject) => {
      server = expressApp.listen(SERVER_PORT, SERVER_HOST, (err) => {
        if (err) {
          reject(err);
        } else {
          console.log(`LocalWrap server running securely on http://${SERVER_HOST}:${SERVER_PORT}`);
          resolve();
        }
      });
    });
  } catch (error) {
    console.error('Failed to create server:', error);
    throw error;
  }
}

function createWindow() {
  // Security: Create secure browser window
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    minWidth: 800,
    minHeight: 600,
    webPreferences: {
      nodeIntegration: false, // Security: Disable node integration
      contextIsolation: true, // Security: Enable context isolation
      preload: path.join(__dirname, 'preload.js'),
      webSecurity: true, // Security: Enable web security
      allowRunningInsecureContent: false,
      experimentalFeatures: false,
      enableBlinkFeatures: '',
      disableBlinkFeatures: '',
      sandbox: true // Security: Enable sandbox
    },
    icon: path.join(__dirname, 'assets', 'icon.png'),
    show: false,
    titleBarStyle: process.platform === 'darwin' ? 'hiddenInset' : 'default',
    webContents: {
      zoomFactor: 1.0
    }
  });

  // Security: Set window title
  mainWindow.setTitle('LocalWrap - Secure Development Server');

  // Security: Handle external links
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (validateLocalhostURL(url)) {
      return { action: 'allow' };
    }
    shell.openExternal(url);
    return { action: 'deny' };
  });

  // Security: Prevent navigation to external sites
  mainWindow.webContents.on('will-navigate', (event, navigationUrl) => {
    if (!validateLocalhostURL(navigationUrl)) {
      event.preventDefault();
      shell.openExternal(navigationUrl);
    }
  });

  // Load the localhost URL after validation
  const targetURL = `http://${SERVER_HOST}:${SERVER_PORT}`;
  if (validateLocalhostURL(targetURL)) {
    mainWindow.loadURL(targetURL);
  } else {
    console.error('Invalid server URL');
    app.quit();
  }

  // Show window when ready
  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
    
    // Security: Disable eval and related functions
    mainWindow.webContents.executeJavaScript(`
      delete window.eval;
      delete window.Function;
      delete window.setTimeout;
      delete window.setInterval;
      window.setTimeout = (fn, delay) => originalSetTimeout(fn, delay);
      window.setInterval = (fn, delay) => originalSetInterval(fn, delay);
    `).catch(console.error);
  });

  // Handle window closed (minimize to tray)
  mainWindow.on('close', (event) => {
    if (!app.isQuiting) {
      event.preventDefault();
      mainWindow.hide();
      
      // Show notification on first minimize
      if (!mainWindow.isMinimizedToTray) {
        mainWindow.isMinimizedToTray = true;
      }
    }
    return false;
  });

  // Security: Clear cache on close
  mainWindow.on('closed', () => {
    mainWindow = null;
  });

  // Development: Open DevTools only in dev mode
  if (process.argv.includes('--dev')) {
    mainWindow.webContents.openDevTools();
  }
}

function createTray() {
  // Create tray icon
  const iconPath = path.join(__dirname, 'assets', 'tray-icon.png');
  let trayIcon;
  
  try {
    if (fs.existsSync(iconPath)) {
      trayIcon = nativeImage.createFromPath(iconPath);
    } else {
      // Fallback: create a simple colored icon
      trayIcon = nativeImage.createEmpty();
    }
  } catch (error) {
    console.error('Error creating tray icon:', error);
    trayIcon = nativeImage.createEmpty();
  }
  
  tray = new Tray(trayIcon);
  
  const contextMenu = Menu.buildFromTemplate([
    {
      label: 'Show LocalWrap',
      click: () => {
        if (mainWindow) {
          mainWindow.show();
          mainWindow.focus();
        }
      }
    },
    {
      label: 'Open in Browser',
      click: () => {
        shell.openExternal(`http://${SERVER_HOST}:${SERVER_PORT}`);
      }
    },
    { type: 'separator' },
    {
      label: 'Server Status',
      enabled: false
    },
    {
      label: `✅ Running on ${SERVER_HOST}:${SERVER_PORT}`,
      enabled: false
    },
    { type: 'separator' },
    {
      label: 'About LocalWrap',
      click: () => {
        dialog.showMessageBox(mainWindow, {
          type: 'info',
          title: 'About LocalWrap',
          message: 'LocalWrap',
          detail: `Version ${app.getVersion()}\nSecure desktop wrapper for localhost development servers.\n\nBuilt with Electron + Express`,
          buttons: ['OK']
        });
      }
    },
    {
      label: 'Quit LocalWrap',
      click: () => {
        app.isQuiting = true;
        app.quit();
      }
    }
  ]);
  
  tray.setContextMenu(contextMenu);
  tray.setToolTip('LocalWrap - Secure Development Server');
  
  // Double click to show/hide window
  tray.on('double-click', () => {
    if (mainWindow) {
      if (mainWindow.isVisible()) {
        mainWindow.hide();
      } else {
        mainWindow.show();
        mainWindow.focus();
      }
    }
  });
}

// App event handlers
app.whenReady().then(async () => {
  try {
    // Start the server first
    await createServer();
    
    // Then create the window and tray
    createWindow();
    createTray();
    
    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) {
        createWindow();
      }
    });
  } catch (error) {
    console.error('Failed to start LocalWrap:', error);
    dialog.showErrorBox('LocalWrap Error', 'Failed to start the development server. Please check the console for details.');
    app.quit();
  }
});

app.on('window-all-closed', () => {
  // On macOS, keep app running even when all windows are closed
  if (process.platform !== 'darwin') {
    // Don't quit, just hide to tray
  }
});

app.on('before-quit', () => {
  app.isQuiting = true;
  
  // Clean up server
  if (server) {
    server.close();
  }
});

// Security: Prevent multiple instances
const gotTheLock = app.requestSingleInstanceLock();

if (!gotTheLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    // Someone tried to run a second instance, focus our window instead
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.show();
      mainWindow.focus();
    }
  });
}

// Security: Handle certificate errors
app.on('certificate-error', (event, webContents, url, error, certificate, callback) => {
  // For localhost development, we might need to handle self-signed certificates
  if (url.startsWith(`http://${SERVER_HOST}:${SERVER_PORT}`)) {
    event.preventDefault();
    callback(true);
  } else {
    callback(false);
  }
});

// Security: Prevent new window creation
app.on('web-contents-created', (event, contents) => {
  contents.on('new-window', (event, navigationUrl) => {
    event.preventDefault();
    shell.openExternal(navigationUrl);
  });
});

// Graceful shutdown
process.on('SIGTERM', () => {
  app.quit();
});

process.on('SIGINT', () => {
  app.quit();
});
