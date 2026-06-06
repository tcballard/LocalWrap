const { app, BrowserWindow, Menu, Tray, nativeImage, shell, dialog, ipcMain } = require('electron');
const fs = require('fs');
const path = require('path');
const { autoUpdater } = require('electron-updater');
const { discoverPackageScripts } = require('./lib/packageScripts');
const { findAvailablePort } = require('./lib/portUtils');
const { ProjectLifecycle } = require('./lib/projectLifecycle');
const { ProjectStore } = require('./lib/projectStore');
const { validateLocalProjectURL } = require('./lib/urlValidation');

let mainWindow;
let tray;
let projectStore;
let projectLifecycle;

function getProjectsFilePath() {
  return path.join(app.getPath('userData'), 'projects.json');
}

function createProjectStore() {
  return new ProjectStore({
    filePath: getProjectsFilePath(),
  });
}

function serializeProject(project) {
  return {
    ...project,
    runtime: projectLifecycle
      ? projectLifecycle.getState(project.id)
      : { status: 'stopped', logs: [] },
  };
}

function serializeProjects() {
  return projectStore.list().map(serializeProject);
}

function getProjectOrThrow(projectId) {
  const project = projectStore.get(projectId);
  if (!project) {
    throw new Error('Project not found.');
  }
  return project;
}

function sendToRenderer(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload);
  }
}

function emitProjectListChanged() {
  sendToRenderer('project:list-changed', serializeProjects());
  refreshTray();
}

function openProject(project) {
  if (!validateLocalProjectURL(project.url)) {
    throw new Error('Project URL must be local.');
  }
  shell.openExternal(project.url);
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1120,
    height: 760,
    minWidth: 860,
    minHeight: 620,
    resizable: true,
    center: true,
    backgroundColor: '#f0f0f0',
    autoHideMenuBar: true,
    show: false,
    icon: path.join(__dirname, 'assets', 'icon.png'),
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      preload: path.join(__dirname, 'preload.js'),
      webSecurity: true,
      allowRunningInsecureContent: false,
      sandbox: true,
    },
  });

  mainWindow.setTitle('LocalWrap - Project Launcher');

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (validateLocalProjectURL(url)) {
      shell.openExternal(url);
    }
    return { action: 'deny' };
  });

  mainWindow.webContents.on('will-navigate', (event, navigationUrl) => {
    const appURL = mainWindow.webContents.getURL();
    if (navigationUrl === appURL) {
      return;
    }

    event.preventDefault();
    if (validateLocalProjectURL(navigationUrl)) {
      shell.openExternal(navigationUrl);
    }
  });

  mainWindow.loadFile(path.join(__dirname, 'public', 'app.html'));

  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
  });

  mainWindow.on('close', (event) => {
    if (!app.isQuiting) {
      event.preventDefault();
      mainWindow.hide();
    }
    return false;
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

function checkForUpdates({ silent = false } = {}) {
  if (!app.isPackaged) {
    if (!silent) {
      dialog.showMessageBox(mainWindow, {
        type: 'info',
        title: 'Check for Updates',
        message: 'Updates are only available in the installed app.',
        buttons: ['OK'],
      });
    }
    return;
  }

  autoUpdater.checkForUpdatesAndNotify().catch((err) => {
    console.error('Update check failed:', err);
    if (!silent) {
      dialog.showErrorBox('Update check failed', err.message);
    }
  });
}

function createTrayMenuTemplate() {
  const projects = projectStore ? serializeProjects() : [];
  const activeProjects = projects.filter((project) =>
    ['starting', 'running', 'ready', 'stopping'].includes(project.runtime.status)
  );
  const readyProjects = projects.filter((project) => project.runtime.status === 'ready');

  return [
    {
      label: 'Show LocalWrap',
      click: () => {
        if (mainWindow) {
          mainWindow.show();
          mainWindow.focus();
        }
      },
    },
    {
      label: 'Open Ready Projects',
      enabled: readyProjects.length > 0,
      click: () => {
        readyProjects.forEach(openProject);
      },
    },
    { type: 'separator' },
    {
      label: `${activeProjects.length} running / ${projects.length} saved project(s)`,
      enabled: false,
    },
    { type: 'separator' },
    {
      label: 'Check for Updates...',
      click: () => checkForUpdates(),
    },
    {
      label: 'About LocalWrap',
      click: () => {
        dialog.showMessageBox(mainWindow, {
          type: 'info',
          title: 'About LocalWrap',
          message: 'LocalWrap',
          detail: `Version ${app.getVersion()}\nSecure desktop launcher for local development projects.\n\nBuilt with Electron`,
          buttons: ['OK'],
        });
      },
    },
    {
      label: 'Quit LocalWrap',
      click: () => {
        app.isQuiting = true;
        app.quit();
      },
    },
  ];
}

function refreshTray() {
  if (tray) {
    tray.setContextMenu(Menu.buildFromTemplate(createTrayMenuTemplate()));
  }
}

function createTray() {
  const iconPath = path.join(__dirname, 'assets', 'tray-icon.png');
  let trayIcon;

  try {
    if (fs.existsSync(iconPath)) {
      trayIcon = nativeImage.createFromPath(iconPath);
      if (process.platform === 'darwin' && trayIcon.resize) {
        trayIcon = trayIcon.resize({ width: 16, height: 16 });
      }
    } else {
      trayIcon = nativeImage.createEmpty();
    }
  } catch (error) {
    console.error('Error creating tray icon:', error);
    trayIcon = nativeImage.createEmpty();
  }

  tray = new Tray(trayIcon);
  refreshTray();
  tray.setToolTip('LocalWrap - Project Launcher');

  tray.on('double-click', () => {
    if (!mainWindow) return;

    if (mainWindow.isVisible()) {
      mainWindow.hide();
    } else {
      mainWindow.show();
      mainWindow.focus();
    }
  });
}

function assertSafeProjectMutation(projectId, patch = {}) {
  const project = getProjectOrThrow(projectId);
  if (!projectLifecycle.isActive(projectId)) {
    return;
  }

  for (const key of ['cwd', 'command', 'port', 'url']) {
    if (Object.prototype.hasOwnProperty.call(patch, key) && patch[key] !== project[key]) {
      throw new Error('Stop the project before changing its directory, command, port, or URL.');
    }
  }
}

function registerIpcHandlers() {
  ipcMain.handle('project:list', () => serializeProjects());

  ipcMain.handle('project:create', async (_event, payload = {}) => {
    const project = projectStore.create(payload);
    emitProjectListChanged();

    if (project.autostart) {
      projectLifecycle.start(project).catch((error) => console.error('Autostart failed:', error));
    }

    return serializeProject(project);
  });

  ipcMain.handle('project:suggestPort', (_event, preferredPort = 3000) =>
    findAvailablePort(preferredPort)
  );

  ipcMain.handle('project:update', (_event, projectId, patch = {}) => {
    assertSafeProjectMutation(projectId, patch);
    const project = projectStore.update(projectId, patch);
    emitProjectListChanged();
    return serializeProject(project);
  });

  ipcMain.handle('project:delete', async (_event, projectId) => {
    await projectLifecycle.stop(projectId);
    projectStore.delete(projectId);
    emitProjectListChanged();
    return true;
  });

  ipcMain.handle('project:start', async (_event, projectId) => {
    const project = getProjectOrThrow(projectId);
    const state = await projectLifecycle.start(project);
    emitProjectListChanged();
    return state;
  });

  ipcMain.handle('project:stop', async (_event, projectId) => {
    const state = await projectLifecycle.stop(projectId);
    emitProjectListChanged();
    return state;
  });

  ipcMain.handle('project:restart', async (_event, projectId) => {
    const project = getProjectOrThrow(projectId);
    const state = await projectLifecycle.restart(project);
    emitProjectListChanged();
    return state;
  });

  ipcMain.handle('project:open', (_event, projectId) => {
    const project = getProjectOrThrow(projectId);
    openProject(project);
    return true;
  });

  ipcMain.handle('project:discoverScripts', (_event, cwd) => discoverPackageScripts(cwd));

  ipcMain.handle('dir:select', async () => {
    const result = await dialog.showOpenDialog(mainWindow, {
      title: 'Select project directory',
      properties: ['openDirectory'],
    });

    if (result.canceled || result.filePaths.length === 0) {
      return null;
    }

    return result.filePaths[0];
  });

  ipcMain.handle('dir:current', () => process.cwd());
}

async function startAutostartProjects() {
  const projects = projectStore.list().filter((project) => project.autostart);
  for (const project of projects) {
    try {
      await projectLifecycle.start(project);
    } catch (error) {
      console.error(`Failed to autostart ${project.name}:`, error);
    }
  }
}

app.whenReady().then(async () => {
  try {
    projectStore = createProjectStore();
    projectLifecycle = new ProjectLifecycle({ openProject });
    projectLifecycle.on('event', (event) => {
      sendToRenderer('project:event', event);
      if (event.type === 'state') {
        refreshTray();
      }
    });

    registerIpcHandlers();
    createWindow();
    createTray();
    await startAutostartProjects();
    checkForUpdates({ silent: true });

    app.on('activate', () => {
      if (BrowserWindow.getAllWindows().length === 0) {
        createWindow();
      } else if (mainWindow) {
        mainWindow.show();
      }
    });
  } catch (error) {
    console.error('Failed to start LocalWrap:', error);
    dialog.showErrorBox(
      'LocalWrap Error',
      'Failed to start LocalWrap. Please check the console for details.'
    );
    app.quit();
  }
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    // Keep the tray process alive.
  }
});

app.on('before-quit', () => {
  app.isQuiting = true;
  if (projectLifecycle) {
    projectLifecycle.stopAll().catch((error) => console.error('Failed to stop projects:', error));
  }
});

const gotTheLock = app.requestSingleInstanceLock();

if (!gotTheLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (mainWindow) {
      if (mainWindow.isMinimized()) mainWindow.restore();
      mainWindow.show();
      mainWindow.focus();
    }
  });
}

app.on('certificate-error', (event, _webContents, url, _error, _certificate, callback) => {
  if (validateLocalProjectURL(url)) {
    event.preventDefault();
    callback(true);
  } else {
    callback(false);
  }
});

app.on('web-contents-created', (_event, contents) => {
  contents.on('new-window', (event, navigationUrl) => {
    event.preventDefault();
    if (validateLocalProjectURL(navigationUrl)) {
      shell.openExternal(navigationUrl);
    }
  });
});

process.on('SIGTERM', () => {
  app.quit();
});

process.on('SIGINT', () => {
  app.quit();
});
