// LocalWrap renderer logic.
//
// Loaded as an external same-origin script so it satisfies the strict CSP
// (`script-src 'self'`). Inline event handlers are likewise disallowed
// (`script-src-attr 'none'`), so all UI wiring uses addEventListener below.

let servers = [];
let currentServerPort = parseInt(window.location.port) || 3000;

// Server Management Functions
async function startServer() {
    const port = parseInt(document.getElementById('portInput').value);
    if (!port || port < 1000 || port > 65535) {
        alert('Please enter a valid port number (1000-65535)');
        return;
    }

    try {
        const response = await fetch(`/api/servers/${port}/start`, { method: 'POST' });
        const result = await response.json();

        if (result.success) {
            showMessage(`Server started on port ${port}`, 'success');
            await refreshServers();
        } else {
            showMessage(result.error || 'Failed to start server', 'error');
        }
    } catch (error) {
        showMessage('Error starting server: ' + error.message, 'error');
    }
}

async function stopServer() {
    const port = parseInt(document.getElementById('portInput').value);
    if (!port) {
        alert('Please enter a port number');
        return;
    }

    try {
        const response = await fetch(`/api/servers/${port}/stop`, { method: 'POST' });
        const result = await response.json();

        if (result.success) {
            showMessage(`Server stopped on port ${port}`, 'success');
            await refreshServers();
        } else {
            showMessage(result.error || 'Failed to stop server', 'error');
        }
    } catch (error) {
        showMessage('Error stopping server: ' + error.message, 'error');
    }
}

async function restartServer() {
    const port = parseInt(document.getElementById('portInput').value);
    if (!port) {
        alert('Please enter a port number');
        return;
    }

    try {
        const response = await fetch(`/api/servers/${port}/restart`, { method: 'POST' });
        const result = await response.json();

        if (result.success) {
            showMessage(`Server restarted on port ${port}`, 'success');
            await refreshServers();
        } else {
            showMessage(result.error || 'Failed to restart server', 'error');
        }
    } catch (error) {
        showMessage('Error restarting server: ' + error.message, 'error');
    }
}

async function refreshServers() {
    try {
        const response = await fetch('/api/servers');
        const data = await response.json();
        servers = data.servers || [];
        updateServerList();
    } catch (error) {
        const serverList = document.getElementById('serverList');
        serverList.textContent = '';
        const err = document.createElement('div');
        err.style.color = 'red';
        err.textContent = 'Error loading servers: ' + error.message;
        serverList.appendChild(err);
    }
}

function updateServerList() {
    const serverList = document.getElementById('serverList');
    serverList.textContent = '';

    if (servers.length === 0) {
        const empty = document.createElement('div');
        empty.style.color = '#666';
        empty.textContent = 'No servers running';
        serverList.appendChild(empty);
        return;
    }

    servers.forEach(server => {
        const item = document.createElement('div');
        item.className = 'server-item';

        const url = document.createElement('span');
        url.className = 'server-url';
        url.textContent = server.url;
        url.addEventListener('click', () => openServer(server.url));

        const status = document.createElement('span');
        status.className = 'server-status';
        status.textContent = server.status;

        item.appendChild(url);
        item.appendChild(status);
        serverList.appendChild(item);
    });
}

function openServer(url) {
    window.open(url, '_blank');
}

function openCurrentServer() {
    const currentUrl = `http://localhost:${currentServerPort}`;
    window.open(currentUrl, '_blank');
}

function refreshAll() {
    refreshServers();
}

function showMessage(message, type) {
    // Simple message display - could be enhanced with a toast notification
    const color = type === 'error' ? 'red' : 'green';
    console.log(`%c${message}`, `color: ${color}; font-weight: bold;`);

    // Update status bar temporarily
    const statusBar = document.querySelector('.status-bar');
    const originalText = statusBar.textContent;
    statusBar.textContent = message;
    statusBar.style.color = color;

    setTimeout(() => {
        statusBar.textContent = originalText;
        statusBar.style.color = '';
    }, 3000);
}

// Wire static control buttons (inline onclick is blocked by CSP).
function wireControls() {
    const bind = (id, handler) => {
        const el = document.getElementById(id);
        if (el) el.addEventListener('click', handler);
    };
    bind('startServerBtn', startServer);
    bind('stopServerBtn', stopServer);
    bind('restartServerBtn', restartServer);
    bind('openServerBtn', openCurrentServer);
    bind('refreshBtn', refreshAll);
    bind('closeBtn', () => window.close());
}

// ===== Dev Script Runner (desktop-only, via contextBridge) =====
function initScriptRunner() {
    const api = window.localwrapAPI;
    const available = !!(api && typeof api.runScript === 'function');

    const controls = document.getElementById('scriptControls');
    const unavailable = document.getElementById('scriptUnavailable');

    // In a plain browser the preload never runs, so the capability does
    // not exist. Hide the controls and explain why.
    if (!available) {
        if (controls) controls.style.display = 'none';
        if (unavailable) unavailable.style.display = 'block';
        return;
    }

    const dirInput = document.getElementById('workingDirInput');
    const scriptInput = document.getElementById('scriptInput');
    const portInput = document.getElementById('scriptPortInput');
    const runBtn = document.getElementById('runScriptBtn');
    const stopBtn = document.getElementById('stopScriptBtn');
    const browseBtn = document.getElementById('browseDirBtn');
    const resetBtn = document.getElementById('resetDirBtn');
    const terminal = document.getElementById('scriptTerminal');

    let currentPid = null;
    let defaultDir = '';

    function appendTerminal(text) {
        const line = document.createElement('div');
        line.className = 'terminal-line';
        line.textContent = text;
        terminal.appendChild(line);
        terminal.scrollTop = terminal.scrollHeight;
    }

    function setRunning(running) {
        runBtn.disabled = running;
        stopBtn.disabled = !running;
        scriptInput.disabled = running;
        portInput.disabled = running;
    }

    api.getCurrentDirectory()
        .then((dir) => { defaultDir = dir || ''; dirInput.value = defaultDir; })
        .catch(() => {});

    api.onScriptOutput(({ pid, line }) => {
        if (pid === currentPid) appendTerminal(line);
    });
    api.onScriptExit(({ pid }) => {
        if (pid === currentPid) { setRunning(false); currentPid = null; }
    });

    browseBtn.addEventListener('click', async () => {
        const dir = await api.selectDirectory();
        if (dir) dirInput.value = dir;
    });

    resetBtn.addEventListener('click', () => {
        dirInput.value = defaultDir;
    });

    runBtn.addEventListener('click', async () => {
        const command = scriptInput.value.trim();
        if (!command) {
            showMessage('Enter a command to run (e.g. npm start)', 'error');
            return;
        }
        const port = parseInt(portInput.value, 10);
        try {
            setRunning(true);
            appendTerminal('> ' + command);
            const result = await api.runScript({
                command,
                port,
                workingDir: dirInput.value || undefined,
            });
            currentPid = result.pid;
            if (result.port && result.port !== port) {
                portInput.value = result.port;
                appendTerminal('[using port ' + result.port + ']');
            }
            showMessage('Running: ' + command, 'success');
        } catch (error) {
            setRunning(false);
            appendTerminal('[error] ' + error.message);
            showMessage('Failed to run script: ' + error.message, 'error');
        }
    });

    stopBtn.addEventListener('click', async () => {
        if (currentPid == null) return;
        try {
            await api.stopScript(currentPid);
            showMessage('Stopping script...', 'success');
        } catch (error) {
            showMessage('Failed to stop script: ' + error.message, 'error');
        }
    });
}

// Initialize on page load
wireControls();
initScriptRunner();
refreshServers();

// Auto-refresh every 10 seconds
setInterval(refreshServers, 10000);
