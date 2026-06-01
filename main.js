const { app, BrowserWindow, Menu, Tray, nativeImage, shell, dialog, ipcMain } = require('electron');
const path = require('path');
const fs = require('fs');
const url = require('url');
const { spawn } = require('child_process');
const { validateScriptCommand } = require('./lib/scriptValidation');

let mainWindow;
let tray;

// Dev-script execution state: pid -> { child, command, port, output }
const runningScripts = new Map();
const MAX_OUTPUT_LINES = 500;

// Server Management System
const servers = new Map(); // port -> server instance
const SERVER_HOST = 'localhost';
const DEFAULT_PORT = process.env.PORT || 
                    process.argv.find(arg => arg.startsWith('--port='))?.split('=')[1] || 
                    3000;

console.log(`🚀 LocalWrap initializing with default port ${DEFAULT_PORT}`);

// Security: Validate that URL is actually localhost
function validateLocalhostURL(targetURL) {
  try {
    const parsedURL = new URL(targetURL);
    const port = parseInt(parsedURL.port);
    return (
      (parsedURL.hostname === 'localhost' || parsedURL.hostname === '127.0.0.1') &&
      port >= 1000 && port <= 65535 && // Valid port range
      parsedURL.protocol === 'http:'
    );
  } catch (error) {
    console.error('Invalid URL:', error);
    return false;
  }
}

// Server Management Functions
async function checkPortAvailable(port) {
  return new Promise((resolve) => {
    const net = require('net');
    const server = net.createServer();
    
    server.listen(port, (err) => {
      if (err) {
        resolve(false);
      } else {
        server.once('close', () => resolve(true));
        server.close();
      }
    });
    
    server.on('error', () => resolve(false));
  });
}

// Find a free port at or after `preferred` (bounded scan).
async function findAvailablePort(preferred) {
  let candidate = preferred;
  for (let i = 0; i < 100 && candidate <= 65535; i++, candidate++) {
    if (await checkPortAvailable(candidate)) {
      return candidate;
    }
  }
  throw new Error('No available port found.');
}

async function startServer(port) {
  try {
    // Check if server already running on this port
    if (servers.has(port)) {
      throw new Error(`Server already running on port ${port}`);
    }
    
    // Check if port is available
    const available = await checkPortAvailable(port);
    if (!available) {
      throw new Error(`Port ${port} is already in use by another application`);
    }
    
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
        version: app.getVersion(),
        port: port,
        host: SERVER_HOST,
        url: `http://${SERVER_HOST}:${port}`
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
    
    // Server Management API Endpoints
    expressApp.get('/api/servers', (req, res) => {
      res.json({
        servers: getServersStatus(),
        total: servers.size
      });
    });
    
    expressApp.post('/api/servers/:port/start', async (req, res) => {
      try {
        const targetPort = parseInt(req.params.port);
        if (isNaN(targetPort) || targetPort < 1000 || targetPort > 65535) {
          return res.status(400).json({ error: 'Invalid port number (1000-65535)' });
        }
        
        await startServer(targetPort);
        res.json({ 
          success: true, 
          message: `Server started on port ${targetPort}`,
          server: getServerStatus(targetPort)
        });
      } catch (error) {
        res.status(400).json({ 
          error: error.message,
          success: false 
        });
      }
    });
    
    expressApp.post('/api/servers/:port/stop', async (req, res) => {
      try {
        const targetPort = parseInt(req.params.port);
        if (isNaN(targetPort)) {
          return res.status(400).json({ error: 'Invalid port number' });
        }
        
        await stopServer(targetPort);
        res.json({ 
          success: true, 
          message: `Server stopped on port ${targetPort}`
        });
      } catch (error) {
        res.status(400).json({ 
          error: error.message,
          success: false 
        });
      }
    });
    
    expressApp.post('/api/servers/:port/restart', async (req, res) => {
      try {
        const targetPort = parseInt(req.params.port);
        if (isNaN(targetPort)) {
          return res.status(400).json({ error: 'Invalid port number' });
        }
        
        await restartServer(targetPort);
        res.json({ 
          success: true, 
          message: `Server restarted on port ${targetPort}`,
          server: getServerStatus(targetPort)
        });
      } catch (error) {
        res.status(400).json({ 
          error: error.message,
          success: false 
        });
      }
    });
    
    expressApp.get('/api/servers/:port/status', (req, res) => {
      const targetPort = parseInt(req.params.port);
      if (isNaN(targetPort)) {
        return res.status(400).json({ error: 'Invalid port number' });
      }
      
      res.json(getServerStatus(targetPort));
    });
    
    // Serve main page
    expressApp.get('/', (req, res) => {
      res.sendFile(path.join(__dirname, 'public', 'app.html'));
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
      const server = expressApp.listen(port, SERVER_HOST, (err) => {
        if (err) {
          reject(err);
        } else {
          // Store server instance
          servers.set(port, {
            instance: server,
            app: expressApp,
            port: port,
            status: 'running',
            startTime: new Date()
          });
          
          console.log(`✅ LocalWrap server started on http://${SERVER_HOST}:${port}`);
          resolve(server);
        }
      });
    });
  } catch (error) {
    console.error(`Failed to start server on port ${port}:`, error);
    throw error;
  }
}

async function stopServer(port) {
  try {
    const serverInfo = servers.get(port);
    if (!serverInfo) {
      throw new Error(`No server running on port ${port}`);
    }
    
    return new Promise((resolve) => {
      serverInfo.instance.close(() => {
        servers.delete(port);
        console.log(`🛑 LocalWrap server stopped on port ${port}`);
        resolve();
      });
    });
  } catch (error) {
    console.error(`Failed to stop server on port ${port}:`, error);
    throw error;
  }
}

async function restartServer(port) {
  try {
    await stopServer(port);
    await new Promise(resolve => setTimeout(resolve, 1000)); // Wait 1 second
    await startServer(port);
    console.log(`🔄 LocalWrap server restarted on port ${port}`);
  } catch (error) {
    console.error(`Failed to restart server on port ${port}:`, error);
    throw error;
  }
}

function getServersStatus() {
  const status = [];
  for (const [port, serverInfo] of servers.entries()) {
    status.push({
      port: port,
      status: serverInfo.status,
      url: `http://${SERVER_HOST}:${port}`,
      startTime: serverInfo.startTime,
      uptime: Date.now() - serverInfo.startTime.getTime()
    });
  }
  return status;
}

function getServerStatus(port) {
  const serverInfo = servers.get(port);
  if (!serverInfo) {
    return { port: port, status: 'stopped' };
  }
  
  return {
    port: port,
    status: serverInfo.status,
    url: `http://${SERVER_HOST}:${port}`,
    startTime: serverInfo.startTime,
    uptime: Date.now() - serverInfo.startTime.getTime()
  };
}

function createWindow() {
  // Security: Create secure browser window
  mainWindow = new BrowserWindow({
    // === WINDOW APPEARANCE ===
    width: 1200,              
    height: 800,              
    minWidth: 800,            
    minHeight: 600,           
    
    // === WINDOW BEHAVIOR ===
    resizable: true,          
    center: true,             
    
    // === VISUAL APPEARANCE ===
    backgroundColor: '#667eea', 
    autoHideMenuBar: true,    
    
    // === WINDOW STARTUP ===
    show: false,              
    
    // === SIMPLIFIED SECURITY SETTINGS ===
    webPreferences: {
      nodeIntegration: false,        
      contextIsolation: true,        
      preload: path.join(__dirname, 'preload.js'), // Minimal preload with no IPC
      webSecurity: true,             
      allowRunningInsecureContent: false,
      sandbox: true,                 
      // REMOVED: devTools settings
    },
    
    // === ICON ===
    icon: path.join(__dirname, 'assets', 'icon.png'),
    
    // === NO DEV OPTIONS ===
    // Removed all DevTools functionality
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
  const targetURL = `http://${SERVER_HOST}:${DEFAULT_PORT}`;
  if (validateLocalhostURL(targetURL)) {
    mainWindow.loadURL(targetURL);
  } else {
    console.error('Invalid server URL');
    app.quit();
  }

  // Show window when ready
  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
    // Removed JavaScript injection to eliminate errors
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
  // Removed all DevTools functionality
}

function createTray() {
  // Create tray icon
  const iconPath = path.join(__dirname, 'assets', 'tray-icon.png');
  let trayIcon;
  
  try {
    if (fs.existsSync(iconPath)) {
      trayIcon = nativeImage.createFromPath(iconPath);
      // Ensure proper size for macOS tray
      if (process.platform === 'darwin') {
        trayIcon = trayIcon.resize({ width: 16, height: 16 });
      }
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
      label: 'Open Main Server',
      click: () => {
        shell.openExternal(`http://${SERVER_HOST}:${DEFAULT_PORT}`);
      }
    },
    { type: 'separator' },
    {
      label: 'Server Status',
      enabled: false
    },
    {
      label: `✅ Running ${servers.size} server(s)`,
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

// === IPC HANDLERS (privileged dev-script actions, desktop-only) ===
// These are exposed ONLY through the preload contextBridge, so a plain
// browser hitting the localhost server cannot reach them.

function sendToRenderer(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload);
  }
}

function killRunningScripts() {
  for (const [, info] of runningScripts.entries()) {
    try { info.child.kill(); } catch (_) { /* ignore */ }
  }
  runningScripts.clear();
}

function registerIpcHandlers() {
  // Run a dev script (allowlisted command, no shell on macOS/Linux).
  ipcMain.handle('script:run', async (event, payload = {}) => {
    const { command, port, workingDir } = payload;

    // Throws on disallowed command / shell metacharacters.
    const { command: cmd, args } = validateScriptCommand(command);

    // Validate working directory (default to LocalWrap's cwd).
    let cwd = process.cwd();
    if (workingDir) {
      if (!fs.existsSync(workingDir) || !fs.statSync(workingDir).isDirectory()) {
        throw new Error(`Working directory does not exist: ${workingDir}`);
      }
      cwd = workingDir;
    }

    // Choose a free port (avoid LocalWrap's own ports / busy ports).
    let requestedPort = parseInt(port, 10);
    if (isNaN(requestedPort) || requestedPort < 1000 || requestedPort > 65535) {
      requestedPort = DEFAULT_PORT + 1;
    }
    const actualPort = await findAvailablePort(requestedPort);

    // Windows resolves npm/yarn/etc via a shell; macOS/Linux never use one.
    const isWin = process.platform === 'win32';
    const child = spawn(cmd, args, {
      cwd,
      env: { ...process.env, PORT: String(actualPort) },
      shell: isWin,
    });

    const pid = child.pid;
    const info = { child, command, port: actualPort, output: [] };
    runningScripts.set(pid, info);

    const pushLine = (line) => {
      info.output.push(line);
      if (info.output.length > MAX_OUTPUT_LINES) info.output.shift();
      sendToRenderer('script:output', { pid, line });
    };

    const handleChunk = (buf) => {
      buf.toString().split(/\r?\n/).forEach((line) => {
        if (line.length > 0) pushLine(line);
      });
    };

    child.stdout.on('data', handleChunk);
    child.stderr.on('data', handleChunk);
    child.on('error', (err) => pushLine(`[error] ${err.message}`));
    child.on('close', (code) => {
      pushLine(`[process exited with code ${code}]`);
      runningScripts.delete(pid);
      sendToRenderer('script:exit', { pid, code });
    });

    return { pid, port: actualPort, command };
  });

  // Stop a running script by pid.
  ipcMain.handle('script:stop', (event, pid) => {
    const info = runningScripts.get(pid);
    if (!info) {
      return { success: false, error: 'No running script with that id.' };
    }
    try {
      info.child.kill();
      return { success: true };
    } catch (err) {
      return { success: false, error: err.message };
    }
  });

  // Native folder picker for the working directory.
  ipcMain.handle('dir:select', async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
      title: 'Select working directory',
      properties: ['openDirectory'],
    });
    if (result.canceled || result.filePaths.length === 0) {
      return null;
    }
    return result.filePaths[0];
  });

  ipcMain.handle('dir:current', () => process.cwd());
}

// App event handlers
app.whenReady().then(async () => {
  try {
    // Start the default server
    await startServer(DEFAULT_PORT);
    
    // Then create the window and tray
    createWindow();
    createTray();
    registerIpcHandlers();
    
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

  // Stop any running dev scripts
  killRunningScripts();

  // Clean up all servers
  for (const [port, serverInfo] of servers.entries()) {
    serverInfo.instance.close();
  }
  servers.clear();
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
  if (url.startsWith(`http://${SERVER_HOST}:`)) {
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
