const { app, BrowserWindow, Menu, Tray, nativeImage, shell, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const url = require('url');

let mainWindow;
let tray;

// Server Management System
const servers = new Map(); // port -> server instance
const runningScripts = new Map(); // pid -> script info
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
          scriptSrc: ["'self'", "'unsafe-inline'"],
          scriptSrcAttr: ["'unsafe-inline'"],
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
    
    // Script Execution API Endpoints
    expressApp.post('/api/script/execute', async (req, res) => {
      try {
        const { script, port, workingDir } = req.body;
        
        if (!script || typeof script !== 'string') {
          return res.status(400).json({ error: 'Script command is required' });
        }
        
        if (!port || isNaN(port) || port < 1000 || port > 65535) {
          return res.status(400).json({ error: 'Valid port number (1000-65535) is required' });
        }
        
        const result = await executeScript(script, port, workingDir);
        res.json(result);
      } catch (error) {
        res.status(500).json({ 
          error: error.message,
          success: false 
        });
      }
    });
    
    expressApp.post('/api/script/stop/:pid', async (req, res) => {
      try {
        const pid = parseInt(req.params.pid);
        if (isNaN(pid)) {
          return res.status(400).json({ error: 'Invalid process ID' });
        }
        
        const result = await stopScript(pid);
        res.json(result);
      } catch (error) {
        res.status(500).json({ 
          error: error.message,
          success: false 
        });
      }
    });
    
    expressApp.get('/api/script/output/:pid', (req, res) => {
      try {
        const pid = parseInt(req.params.pid);
        if (isNaN(pid)) {
          return res.status(400).json({ error: 'Invalid process ID' });
        }
        
        const result = getScriptOutput(pid);
        res.json(result);
      } catch (error) {
        res.status(500).json({ 
          error: error.message,
          success: false 
        });
      }
    });
    
    // Desktop App Creation API
    expressApp.post('/api/desktop-app/create', async (req, res) => {
      try {
        const { port, appName } = req.body;
        
        if (!appName || typeof appName !== 'string') {
          return res.status(400).json({ error: 'App name is required' });
        }
        
        if (!port || isNaN(port) || port < 1000 || port > 65535) {
          return res.status(400).json({ error: 'Valid port number (1000-65535) is required' });
        }
        
        const result = await createDesktopApp(appName, port);
        res.json(result);
      } catch (error) {
        res.status(500).json({ 
          error: error.message,
          success: false 
        });
      }
    });
    
    // Directory Management API Endpoints
    expressApp.get('/api/current-directory', (req, res) => {
      try {
        res.json({
          success: true,
          path: process.cwd()
        });
      } catch (error) {
        res.status(500).json({
          error: error.message,
          success: false
        });
      }
    });
    
    expressApp.post('/api/select-directory', async (req, res) => {
      try {
        const result = await selectDirectory();
        res.json(result);
      } catch (error) {
        res.status(500).json({
          error: error.message,
          success: false
        });
      }
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

// Script Execution Functions
async function findAvailablePort(preferredPort) {
  const portsToTry = [preferredPort, 3001, 3002, 8000, 8080, 8081, 5000, 5001];
  
  for (const port of portsToTry) {
    if (port === DEFAULT_PORT) continue; // Skip LocalWrap's port
    const available = await checkPortAvailable(port);
    if (available) {
      return port;
    }
  }
  
  // If none of the common ports work, try random ports
  for (let i = 0; i < 10; i++) {
    const randomPort = Math.floor(Math.random() * (9999 - 3000) + 3000);
    if (randomPort === DEFAULT_PORT) continue;
    const available = await checkPortAvailable(randomPort);
    if (available) {
      return randomPort;
    }
  }
  
  throw new Error('Could not find any available port');
}

async function executeScript(script, port, workingDir = null) {
  try {
    let actualPort = port;
    let portMessage = '';
    
    // Check if the target port conflicts with LocalWrap's own port
    if (port === DEFAULT_PORT) {
      actualPort = await findAvailablePort(port + 1);
      portMessage = `Port ${port} is used by LocalWrap. Using port ${actualPort} instead.`;
    } else {
      // Check if port is available
      const available = await checkPortAvailable(port);
      if (!available) {
        actualPort = await findAvailablePort(port + 1);
        portMessage = `Port ${port} is already in use. Using port ${actualPort} instead.`;
      }
    }
    
    // Validate working directory if provided
    let actualWorkingDir = workingDir || process.cwd();
    if (workingDir) {
      if (!fs.existsSync(workingDir)) {
        throw new Error(`Working directory does not exist: ${workingDir}`);
      }
      
      const stats = fs.statSync(workingDir);
      if (!stats.isDirectory()) {
        throw new Error(`Path is not a directory: ${workingDir}`);
      }
    }
    
    const { spawn } = require('child_process');
    
    // Parse script command and update port if needed
    let [command, ...args] = script.split(' ');
    
    // If script contains a port reference, update it to the actual port
    if (actualPort !== port) {
      args = args.map(arg => arg.replace(port.toString(), actualPort.toString()));
    }
    
    // Create process
    const child = spawn(command, args, {
      cwd: actualWorkingDir,
      env: { ...process.env, PORT: actualPort.toString() },
      stdio: ['pipe', 'pipe', 'pipe']
    });
    
    // Store script info
    const scriptInfo = {
      pid: child.pid,
      command: script,
      actualCommand: actualPort !== port ? `${command} ${args.join(' ')}` : script,
      port: actualPort,
      requestedPort: port,
      workingDir: actualWorkingDir,
      startTime: new Date(),
      process: child,
      output: [],
      running: true,
      portMessage: portMessage
    };
    
    // Add port change message to output if needed
    if (portMessage) {
      scriptInfo.output.push(portMessage);
    }
    
    // Add working directory info to output
    if (workingDir && workingDir !== process.cwd()) {
      scriptInfo.output.push(`Working directory: ${actualWorkingDir}`);
    }
    
    runningScripts.set(child.pid, scriptInfo);
    
    // Handle output
    child.stdout.on('data', (data) => {
      const lines = data.toString().split('\n').filter(line => line.trim());
      lines.forEach(line => {
        scriptInfo.output.push(line);
        // Keep only last 100 lines
        if (scriptInfo.output.length > 100) {
          scriptInfo.output.shift();
        }
      });
    });
    
    child.stderr.on('data', (data) => {
      const lines = data.toString().split('\n').filter(line => line.trim());
      lines.forEach(line => {
        scriptInfo.output.push(`ERROR: ${line}`);
        if (scriptInfo.output.length > 100) {
          scriptInfo.output.shift();
        }
      });
    });
    
    child.on('close', (code) => {
      scriptInfo.running = false;
      scriptInfo.output.push(`Process exited with code ${code}`);
      console.log(`Script ${child.pid} exited with code ${code}`);
    });
    
    child.on('error', (error) => {
      scriptInfo.running = false;
      scriptInfo.output.push(`Process error: ${error.message}`);
      console.error(`Script ${child.pid} error:`, error);
    });
    
    console.log(`✅ Script started: ${scriptInfo.actualCommand || script} (PID: ${child.pid}) on port ${actualPort}`);
    if (portMessage) {
      console.log(`ℹ️  ${portMessage}`);
    }
    
    return {
      success: true,
      pid: child.pid,
      command: script,
      actualCommand: scriptInfo.actualCommand,
      port: actualPort,
      requestedPort: port,
      portMessage: portMessage
    };
  } catch (error) {
    console.error('Failed to execute script:', error);
    throw new Error(`Failed to execute script: ${error.message}`);
  }
}

async function stopScript(pid) {
  try {
    const scriptInfo = runningScripts.get(pid);
    if (!scriptInfo) {
      throw new Error(`No script found with PID ${pid}`);
    }
    
    if (!scriptInfo.running) {
      throw new Error(`Script ${pid} is not running`);
    }
    
    // Kill the process
    scriptInfo.process.kill('SIGTERM');
    
    // Wait a bit, then force kill if necessary
    setTimeout(() => {
      if (scriptInfo.running) {
        scriptInfo.process.kill('SIGKILL');
      }
    }, 5000);
    
    scriptInfo.running = false;
    scriptInfo.output.push('Process terminated by user');
    
    console.log(`🛑 Script stopped: PID ${pid}`);
    
    return {
      success: true,
      pid: pid,
      message: `Script ${pid} stopped`
    };
  } catch (error) {
    console.error('Failed to stop script:', error);
    throw new Error(`Failed to stop script: ${error.message}`);
  }
}

function getScriptOutput(pid) {
  const scriptInfo = runningScripts.get(pid);
  if (!scriptInfo) {
    return {
      success: false,
      error: `No script found with PID ${pid}`
    };
  }
  
  // Track what we've already sent to avoid spam
  if (!scriptInfo.lastSentIndex) {
    scriptInfo.lastSentIndex = 0;
  }
  
  // Only return new output since last request
  const newOutput = scriptInfo.output.slice(scriptInfo.lastSentIndex);
  scriptInfo.lastSentIndex = scriptInfo.output.length;
  
  return {
    success: true,
    output: newOutput, // Return only new lines
    running: scriptInfo.running,
    pid: pid
  };
}

async function createDesktopApp(appName, port) {
  try {
    // Find the current running script for this port
    let currentScript = null;
    for (const [pid, scriptInfo] of runningScripts.entries()) {
      if (scriptInfo.port === port && scriptInfo.running) {
        currentScript = scriptInfo;
        break;
      }
    }
    
    if (!currentScript) {
      throw new Error(`No running script found on port ${port}. Please start a script first.`);
    }
    
    const desktopAppsDir = path.join(require('os').homedir(), 'Desktop', 'LocalWrap-Apps');
    const appDir = path.join(desktopAppsDir, appName);
    
    // Create directories
    if (!fs.existsSync(desktopAppsDir)) {
      fs.mkdirSync(desktopAppsDir, { recursive: true });
    }
    
    if (!fs.existsSync(appDir)) {
      fs.mkdirSync(appDir, { recursive: true });
    }
    
    // Create package.json
    const packageJson = {
      name: appName.toLowerCase().replace(/\s+/g, '-'),
      version: '1.0.0',
      description: `Desktop app that runs: ${currentScript.command}`,
      main: 'main.js',
      scripts: {
        start: 'electron .'
      },
      dependencies: {
        electron: '^32.0.0'
      }
    };
    
    fs.writeFileSync(
      path.join(appDir, 'package.json'),
      JSON.stringify(packageJson, null, 2)
    );
    
    // Create main.js that runs the script AND shows the web view
    const mainJs = `
const { app, BrowserWindow, shell } = require('electron');
const { spawn } = require('child_process');
const path = require('path');

let mainWindow;
let scriptProcess;

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

async function startScript() {
  console.log('Starting script: ${currentScript.command}');
  
  // Parse script command
  const [command, ...args] = '${currentScript.command}'.split(' ');
  
  // Start the script process
  scriptProcess = spawn(command, args, {
    cwd: process.cwd(),
    env: { ...process.env, PORT: '${port}' },
    stdio: ['pipe', 'pipe', 'pipe']
  });
  
  scriptProcess.stdout.on('data', (data) => {
    console.log('Script output:', data.toString());
  });
  
  scriptProcess.stderr.on('data', (data) => {
    console.error('Script error:', data.toString());
  });
  
  scriptProcess.on('close', (code) => {
    console.log('Script exited with code:', code);
  });
  
  scriptProcess.on('error', (error) => {
    console.error('Script process error:', error);
  });
  
  // Wait a bit for the server to start
  await new Promise(resolve => setTimeout(resolve, 3000));
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      webSecurity: true
    },
    title: '${appName}',
    icon: path.join(__dirname, 'icon.png')
  });

  // Handle external links
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });

  // Load the localhost URL
  mainWindow.loadURL('http://localhost:${port}');
  
  mainWindow.on('closed', () => {
    mainWindow = null;
    // Stop the script when window closes
    if (scriptProcess && !scriptProcess.killed) {
      scriptProcess.kill('SIGTERM');
    }
  });
}

app.whenReady().then(async () => {
  // Start the script first
  await startScript();
  
  // Then create the window
  createWindow();
});

app.on('window-all-closed', () => {
  // Stop the script when app quits
  if (scriptProcess && !scriptProcess.killed) {
    scriptProcess.kill('SIGTERM');
  }
  
  if (process.platform !== 'darwin') {
    app.quit();
  }
});

app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    createWindow();
  }
});

app.on('before-quit', () => {
  // Ensure script is stopped
  if (scriptProcess && !scriptProcess.killed) {
    scriptProcess.kill('SIGTERM');
  }
});
`;
    
    fs.writeFileSync(path.join(appDir, 'main.js'), mainJs);
    
    // Copy icon
    const iconSource = path.join(__dirname, 'assets', 'icon.png');
    const iconDest = path.join(appDir, 'icon.png');
    if (fs.existsSync(iconSource)) {
      fs.copyFileSync(iconSource, iconDest);
    }
    
    // Create a README with instructions
    const readme = `# ${appName}

This desktop app runs the following script and displays it in a web browser:

**Script:** \`${currentScript.command}\`
**Port:** ${port}

## To run this app:

1. Install dependencies: \`npm install\`
2. Start the app: \`npm start\`

The app will automatically start the script and open a window showing the web interface.

## What this app does:

1. Runs the script: \`${currentScript.command}\`
2. Waits for the server to start on port ${port}
3. Opens an Electron window pointing to http://localhost:${port}
4. Stops the script when you close the app

Generated by LocalWrap on ${new Date().toISOString()}
`;
    
    fs.writeFileSync(path.join(appDir, 'README.md'), readme);
    
    console.log(`✅ Desktop app created: ${appDir}`);
    console.log(`   Script: ${currentScript.command}`);
    console.log(`   Port: ${port}`);
    
    // Auto-install dependencies and launch the app
    const { spawn } = require('child_process');
    
    console.log(`📦 Installing dependencies for ${appName}...`);
    
    return new Promise((resolve, reject) => {
      // Install npm dependencies
      const npmInstall = spawn('npm', ['install'], {
        cwd: appDir,
        stdio: ['pipe', 'pipe', 'pipe']
      });
      
      npmInstall.on('close', (code) => {
        if (code !== 0) {
          console.error(`npm install failed with code ${code}`);
          reject(new Error(`Failed to install dependencies: npm install exited with code ${code}`));
          return;
        }
        
        console.log(`🚀 Launching ${appName}...`);
        
        // Launch the app
        const appProcess = spawn('npm', ['start'], {
          cwd: appDir,
          detached: true,
          stdio: 'ignore'
        });
        
        // Detach the process so it runs independently
        appProcess.unref();
        
        console.log(`✅ Desktop app launched: ${appName}`);
        
        resolve({
          success: true,
          appName: appName,
          path: appDir,
          port: port,
          script: currentScript.command,
          launched: true
        });
      });
      
      npmInstall.on('error', (error) => {
        console.error(`npm install error:`, error);
        reject(new Error(`Failed to install dependencies: ${error.message}`));
      });
    });
  } catch (error) {
    console.error('Failed to create desktop app:', error);
    throw new Error(`Failed to create desktop app: ${error.message}`);
  }
}

// Directory Selection Function
async function selectDirectory() {
  try {
    const { dialog } = require('electron');
    
    const result = await dialog.showOpenDialog(mainWindow, {
      properties: ['openDirectory'],
      title: 'Select Working Directory',
      buttonLabel: 'Select Directory'
    });
    
    if (result.canceled || !result.filePaths || result.filePaths.length === 0) {
      return {
        success: false,
        cancelled: true,
        message: 'Directory selection cancelled'
      };
    }
    
    const selectedPath = result.filePaths[0];
    
    // Validate the selected directory
    if (!fs.existsSync(selectedPath)) {
      return {
        success: false,
        error: 'Selected directory does not exist'
      };
    }
    
    const stats = fs.statSync(selectedPath);
    if (!stats.isDirectory()) {
      return {
        success: false,
        error: 'Selected path is not a directory'
      };
    }
    
    console.log(`📁 Working directory selected: ${selectedPath}`);
    
    return {
      success: true,
      path: selectedPath
    };
  } catch (error) {
    console.error('Failed to select directory:', error);
    throw new Error(`Failed to select directory: ${error.message}`);
  }
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

// === NO IPC HANDLERS - REMOVED TO ELIMINATE ERRORS ===

// App event handlers
app.whenReady().then(async () => {
  try {
    // Start the default server
    await startServer(DEFAULT_PORT);
    
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
  
  // Clean up all servers
  for (const [port, serverInfo] of servers.entries()) {
    serverInfo.instance.close();
  }
  servers.clear();
  
  // Clean up all running scripts
  for (const [pid, scriptInfo] of runningScripts.entries()) {
    if (scriptInfo.running && scriptInfo.process) {
      console.log(`Stopping script PID ${pid} on app quit`);
      scriptInfo.process.kill('SIGTERM');
    }
  }
  runningScripts.clear();
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
