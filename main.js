const {
  app,
  BrowserView,
  BrowserWindow,
  Menu,
  Tray,
  nativeImage,
  shell,
  dialog,
  ipcMain,
  clipboard,
} = require('electron');
const fs = require('fs');
const path = require('path');
const { autoUpdater } = require('electron-updater');
const { clampPreviewBounds, createIpcHandlers } = require('./lib/ipcHandlers');
const { checkPortAvailable, findAvailablePort } = require('./lib/portUtils');
const { ACTIVE_STATUSES, ProjectLifecycle } = require('./lib/projectLifecycle');
const { ProjectStore, isStoreCorruptError } = require('./lib/projectStore');
const { validateLocalProjectURL } = require('./lib/urlValidation');

let mainWindow;
let tray;
let projectStore;
let projectLifecycle;
let previewController;
let ipcApi;
let lastPersistedWorkspaceKey = '';
let quitCleanupComplete = false;
let quitCleanupPromise = null;

// Lets tests isolate their own config directory; harmless otherwise.
if (process.env.LOCALWRAP_USER_DATA) {
  app.setPath('userData', process.env.LOCALWRAP_USER_DATA);
}

function getProjectsFilePath() {
  return path.join(app.getPath('userData'), 'projects.json');
}

function createProjectStore() {
  return new ProjectStore({
    filePath: getProjectsFilePath(),
  });
}

/**
 * Verify the saved projects file is readable before the app starts using it.
 * On corruption, ask the user to restore the last-good backup or start fresh
 * (the unreadable file is moved aside, never deleted). Returns false when the
 * user chooses to quit instead; startup must stop in that case.
 */
function ensureProjectStoreReadable() {
  for (;;) {
    let error;
    try {
      projectStore.list();
      return true;
    } catch (caught) {
      if (!isStoreCorruptError(caught)) {
        throw caught;
      }
      error = caught;
    }

    const hasBackup = projectStore.hasBackup();
    const buttons = hasBackup ? ['Restore Backup', 'Start Fresh', 'Quit'] : ['Start Fresh', 'Quit'];
    const detailLines = [
      error.message,
      '',
      hasBackup
        ? 'Restore Backup brings back your projects from the last successful save.'
        : 'No backup exists yet (backups are written on every save from now on).',
      'Start Fresh keeps the unreadable file next to it for manual recovery and continues with an empty project list.',
    ];

    const choice = dialog.showMessageBoxSync({
      type: 'error',
      title: 'LocalWrap - Saved Projects Unreadable',
      message: 'Your saved projects file could not be read.',
      detail: detailLines.join('\n'),
      buttons,
      defaultId: 0,
      cancelId: buttons.length - 1,
      noLink: true,
    });
    const action = buttons[choice];

    if (action === 'Quit') {
      app.quit();
      return false;
    }

    if (action === 'Restore Backup') {
      try {
        projectStore.restoreFromBackup();
      } catch (restoreError) {
        console.error('Backup restore failed:', restoreError);
        dialog.showErrorBox(
          'Restore failed',
          `The backup could not be restored: ${restoreError.message}`
        );
      }
      // Loop: re-check the store; on success we return true, on failure the
      // dialog comes back (without a usable backup, Start Fresh remains).
      continue;
    }

    const { preservedPath } = projectStore.startFresh();
    if (preservedPath) {
      console.error(`Unreadable projects file preserved at: ${preservedPath}`);
    }
  }
}

function persistActiveWorkspaceSnapshot() {
  if (!projectStore || !projectLifecycle) {
    return projectStore ? projectStore.getWorkspace() : { lastRunningProjectIds: [] };
  }

  const activeProjectIds = projectLifecycle.getActiveProjectIds();
  if (activeProjectIds.length === 0) {
    return projectStore.getWorkspace();
  }

  const key = activeProjectIds.join('\0');
  if (key === lastPersistedWorkspaceKey) {
    return projectStore.getWorkspace();
  }

  lastPersistedWorkspaceKey = key;
  return projectStore.setLastRunningProjectIds(activeProjectIds);
}

function sendToRenderer(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload);
  }
}

function emitProjectListChanged() {
  sendToRenderer('project:list-changed', ipcApi.serializeProjects());
  refreshTray();
}

function openProject(project) {
  if (!validateLocalProjectURL(project.url)) {
    throw new Error('Project URL must be local.');
  }
  shell.openExternal(project.url);
}

function isWebURL(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch (_error) {
    return false;
  }
}

/**
 * Owns the embedded preview surface (an Electron BrowserView attached to the
 * main window). Project lookup and readiness checks happen in the IPC layer;
 * this controller only does window mechanics.
 */
function createPreviewController() {
  let previewView = null;
  let previewProjectId = null;

  function emitPreviewEvent(payload) {
    sendToRenderer('preview:event', {
      projectId: previewProjectId,
      ...payload,
    });
  }

  function normalizeBounds(bounds) {
    if (!mainWindow || mainWindow.isDestroyed()) {
      throw new Error('Preview window is unavailable.');
    }

    return clampPreviewBounds(bounds, mainWindow.getContentBounds());
  }

  function handlePreviewNavigation(event, navigationUrl) {
    if (validateLocalProjectURL(navigationUrl)) {
      return;
    }

    event.preventDefault();
    if (isWebURL(navigationUrl)) {
      shell.openExternal(navigationUrl);
    }
  }

  function createPreviewView() {
    const view = new BrowserView({
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true,
        sandbox: true,
        webSecurity: true,
        allowRunningInsecureContent: false,
      },
    });

    view.webContents.setWindowOpenHandler(({ url }) => {
      if (validateLocalProjectURL(url)) {
        view.webContents.loadURL(url);
      } else if (isWebURL(url)) {
        shell.openExternal(url);
      }

      return { action: 'deny' };
    });

    view.webContents.on('will-navigate', handlePreviewNavigation);
    view.webContents.on('will-redirect', handlePreviewNavigation);
    view.webContents.on('did-start-loading', () => emitPreviewEvent({ status: 'loading' }));
    view.webContents.on('did-finish-load', () =>
      emitPreviewEvent({ status: 'ready', url: view.webContents.getURL() })
    );
    view.webContents.on('did-fail-load', (_event, errorCode, errorDescription, validatedURL) => {
      if (errorCode === -3) {
        return;
      }

      emitPreviewEvent({
        status: 'failed',
        url: validatedURL,
        message: errorDescription,
      });
    });
    view.webContents.on('did-navigate', (_event, url) =>
      emitPreviewEvent({ status: 'ready', url })
    );

    return view;
  }

  function close(projectId = null) {
    if (projectId && previewProjectId !== projectId) {
      return false;
    }

    if (mainWindow && !mainWindow.isDestroyed() && previewView) {
      mainWindow.setBrowserView(null);
    }

    if (previewView && !previewView.webContents.isDestroyed()) {
      previewView.webContents.close();
    }

    previewView = null;
    previewProjectId = null;
    return true;
  }

  function open(project, bounds) {
    const normalizedBounds = normalizeBounds(bounds);
    if (!previewView || previewView.webContents.isDestroyed()) {
      previewView = createPreviewView();
    }

    previewProjectId = project.id;
    mainWindow.setBrowserView(previewView);
    previewView.setBounds(normalizedBounds);
    previewView.setAutoResize({ width: false, height: false });
    previewView.webContents.loadURL(project.url);

    return {
      projectId: project.id,
      url: project.url,
    };
  }

  function resize(bounds) {
    if (!previewView || previewView.webContents.isDestroyed()) {
      return false;
    }

    previewView.setBounds(normalizeBounds(bounds));
    return true;
  }

  function reload() {
    if (!previewView || previewView.webContents.isDestroyed()) {
      return false;
    }

    previewView.webContents.reloadIgnoringCache();
    return true;
  }

  return { close, open, reload, resize };
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1120,
    height: 760,
    minWidth: 860,
    minHeight: 620,
    resizable: true,
    center: true,
    backgroundColor: '#eef1f3',
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
    previewController.close();
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
  const projects = projectStore && ipcApi ? ipcApi.serializeProjects() : [];
  const activeProjects = projects.filter((project) => ACTIVE_STATUSES.has(project.runtime.status));
  const readyProjects = projects.filter((project) => project.runtime.status === 'ready');
  const workspace = projectStore ? projectStore.getWorkspace() : { lastRunningProjectIds: [] };

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
    {
      label: 'Resume Workspace',
      enabled: activeProjects.length === 0 && workspace.lastRunningProjectIds.length > 0,
      click: () => {
        ipcApi
          .resumeWorkspaceProjects()
          .catch((error) => console.error('Failed to resume workspace:', error));
      },
    },
    {
      label: 'Start All Projects',
      enabled: projects.length > 0,
      click: () => {
        ipcApi
          .startAllProjects()
          .catch((error) => console.error('Failed to start projects:', error));
      },
    },
    {
      label: 'Stop All Running Projects',
      enabled: activeProjects.length > 0,
      click: () => {
        ipcApi.stopAllProjects().catch((error) => console.error('Failed to stop projects:', error));
      },
    },
    { type: 'separator' },
    {
      label: `${activeProjects.length} running / ${projects.length} saved project(s)`,
      enabled: false,
    },
    {
      label: 'Running Projects',
      enabled: activeProjects.length > 0,
      submenu: activeProjects.map((project) => ({
        label: project.name,
        submenu: [
          {
            label: 'Open',
            enabled: project.runtime.status === 'ready',
            click: () => openProject(project),
          },
          {
            label: 'Stop',
            enabled: project.runtime.status !== 'stopping',
            click: () => {
              persistActiveWorkspaceSnapshot();
              projectLifecycle
                .stop(project.id)
                .then(emitProjectListChanged)
                .catch((error) => console.error(`Failed to stop ${project.name}:`, error));
            },
          },
        ],
      })),
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
  if (!tray) {
    return;
  }

  // The menu reads the store; a mid-session read failure must not crash the
  // lifecycle event handler that triggered the refresh.
  try {
    tray.setContextMenu(Menu.buildFromTemplate(createTrayMenuTemplate()));
  } catch (error) {
    console.error('Failed to refresh tray menu:', error);
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

function registerIpcHandlers() {
  ipcApi = createIpcHandlers({
    app,
    clipboard,
    dialog,
    shell,
    projectStore,
    projectLifecycle,
    appRoot: __dirname,
    resourcesPath: process.resourcesPath,
    emitProjectListChanged,
    getMainWindow: () => mainWindow,
    openProject,
    preview: previewController,
    persistActiveWorkspaceSnapshot,
  });

  for (const [channel, handler] of Object.entries(ipcApi.invokeHandlers)) {
    ipcMain.handle(channel, handler);
  }

  for (const [channel, handler] of Object.entries(ipcApi.syncHandlers)) {
    ipcMain.on(channel, (event, ...args) => {
      event.returnValue = handler(...args);
    });
  }
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
    if (!ensureProjectStoreReadable()) {
      return;
    }

    previewController = createPreviewController();
    projectLifecycle = new ProjectLifecycle({ openProject, checkPortAvailable, findAvailablePort });
    projectLifecycle.on('event', (event) => {
      sendToRenderer('project:event', event);
      if (event.type === 'state') {
        persistActiveWorkspaceSnapshot();
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

app.on('before-quit', (event) => {
  app.isQuiting = true;
  if (!projectLifecycle || quitCleanupComplete) {
    return;
  }

  event.preventDefault();
  if (!quitCleanupPromise) {
    quitCleanupPromise = (async () => {
      try {
        persistActiveWorkspaceSnapshot();
        await projectLifecycle.stopAll();
      } catch (error) {
        console.error('Failed to stop projects:', error);
      } finally {
        quitCleanupComplete = true;
        app.quit();
      }
    })();
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

process.on('SIGTERM', () => {
  app.quit();
});

process.on('SIGINT', () => {
  app.quit();
});
