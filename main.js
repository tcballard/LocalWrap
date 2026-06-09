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
const { discoverPackageScripts } = require('./lib/packageScripts');
const { checkPortAvailable, findAvailablePort } = require('./lib/portUtils');
const {
  ACTIONS: DOCTOR_ACTIONS,
  buildDoctorReport,
  diagnoseProjectDraft: runProjectDoctor,
  getDoctorActionPatch,
} = require('./lib/projectDoctor');
const { inspectProjectDirectory } = require('./lib/projectInspection');
const { ACTIVE_STATUSES, ProjectLifecycle } = require('./lib/projectLifecycle');
const { ProjectStore } = require('./lib/projectStore');
const { createSampleProject } = require('./lib/sampleProject');
const { validateProjectDraft } = require('./lib/projectValidation');
const { validateLocalProjectURL } = require('./lib/urlValidation');

let mainWindow;
let tray;
let projectStore;
let projectLifecycle;
let previewView;
let previewProjectId;

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

function serializeRuntime(projectId) {
  return projectLifecycle
    ? projectLifecycle.getState(projectId)
    : { status: 'stopped', logs: [], diagnosis: null };
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

function isWebURL(url) {
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch (_error) {
    return false;
  }
}

function emitPreviewEvent(payload) {
  sendToRenderer('preview:event', {
    projectId: previewProjectId,
    ...payload,
  });
}

function normalizePreviewBounds(bounds = {}) {
  if (!mainWindow || mainWindow.isDestroyed()) {
    throw new Error('Preview window is unavailable.');
  }

  const contentBounds = mainWindow.getContentBounds();
  const x = Math.max(0, Math.floor(Number(bounds.x) || 0));
  const y = Math.max(0, Math.floor(Number(bounds.y) || 0));
  const width = Math.floor(Number(bounds.width) || 0);
  const height = Math.floor(Number(bounds.height) || 0);
  const clampedWidth = Math.max(0, Math.min(width, contentBounds.width - x));
  const clampedHeight = Math.max(0, Math.min(height, contentBounds.height - y));

  if (clampedWidth < 120 || clampedHeight < 80) {
    throw new Error('Preview area is too small.');
  }

  return {
    x,
    y,
    width: clampedWidth,
    height: clampedHeight,
  };
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
  view.webContents.on('did-navigate', (_event, url) => emitPreviewEvent({ status: 'ready', url }));

  return view;
}

function closeProjectPreview(projectId = null) {
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

function previewProject(project, bounds) {
  if (!validateLocalProjectURL(project.url)) {
    throw new Error('Project URL must be local.');
  }

  const runtime = serializeRuntime(project.id);
  if (runtime.status !== 'ready') {
    throw new Error('Project must be ready before previewing it in LocalWrap.');
  }

  const normalizedBounds = normalizePreviewBounds(bounds);
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

function resizeProjectPreview(bounds) {
  if (!previewView || previewView.webContents.isDestroyed()) {
    return false;
  }

  previewView.setBounds(normalizePreviewBounds(bounds));
  return true;
}

function reloadProjectPreview() {
  if (!previewView || previewView.webContents.isDestroyed()) {
    return false;
  }

  previewView.webContents.reloadIgnoringCache();
  return true;
}

function revealProjectDirectory(project) {
  if (!fs.existsSync(project.cwd) || !fs.statSync(project.cwd).isDirectory()) {
    throw new Error('Project directory does not exist.');
  }
  return shell.openPath(project.cwd);
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
    closeProjectPreview();
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
  const activeProjects = projects.filter((project) => ACTIVE_STATUSES.has(project.runtime.status));
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
    {
      label: 'Stop All Running Projects',
      enabled: activeProjects.length > 0,
      click: () => {
        projectLifecycle
          .stopAll()
          .then(emitProjectListChanged)
          .catch((error) => console.error('Failed to stop projects:', error));
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

async function applyDoctorAction(projectId, actionId) {
  const project = getProjectOrThrow(projectId);

  if (actionId === DOCTOR_ACTIONS.REVEAL_DIRECTORY) {
    await revealProjectDirectory(project);
    return serializeProject(project);
  }

  if (actionId === DOCTOR_ACTIONS.USE_FREE_PORT) {
    const port = await findAvailablePort(project.port);
    const patch = getDoctorActionPatch(project, actionId, { port });
    assertSafeProjectMutation(projectId, patch);
    const updated = projectStore.update(projectId, patch);
    emitProjectListChanged();
    return serializeProject(updated);
  }

  if (actionId === DOCTOR_ACTIONS.SYNC_URL_TO_PORT) {
    const patch = getDoctorActionPatch(project, actionId);
    assertSafeProjectMutation(projectId, patch);
    const updated = projectStore.update(projectId, patch);
    emitProjectListChanged();
    return serializeProject(updated);
  }

  throw new Error(`Unknown Project Doctor action: ${actionId}`);
}

function registerIpcHandlers() {
  ipcMain.handle('project:list', () => serializeProjects());

  ipcMain.handle('project:inspectDirectory', (_event, cwd) =>
    inspectProjectDirectory(cwd, {
      findAvailablePort,
    })
  );

  ipcMain.handle('project:validateDraft', (_event, draft) =>
    validateProjectDraft(draft, {
      checkPortAvailable,
    })
  );

  ipcMain.handle('project:diagnoseDraft', (_event, draft) =>
    runProjectDoctor(draft, {
      checkPortAvailable,
      findAvailablePort,
    })
  );

  ipcMain.handle('project:create', async (_event, payload = {}) => {
    const project = projectStore.create(payload);
    emitProjectListChanged();

    if (project.autostart) {
      projectLifecycle.start(project).catch((error) => console.error('Autostart failed:', error));
    }

    return serializeProject(project);
  });

  ipcMain.handle('project:createSample', async () => {
    const project = await createSampleProject({
      app,
      appRoot: __dirname,
      findAvailablePort,
      inspectProjectDirectory,
      projectStore,
      resourcesPath: process.resourcesPath,
    });
    emitProjectListChanged();
    return serializeProject(project);
  });

  ipcMain.handle('project:suggestPort', (_event, preferredPort = 3000) =>
    findAvailablePort(preferredPort)
  );

  ipcMain.handle('project:checkPort', async (_event, port) => ({
    port,
    available: await checkPortAvailable(port),
  }));

  ipcMain.handle('project:update', (_event, projectId, patch = {}) => {
    assertSafeProjectMutation(projectId, patch);
    const project = projectStore.update(projectId, patch);
    emitProjectListChanged();
    return serializeProject(project);
  });

  ipcMain.handle('project:delete', async (_event, projectId) => {
    closeProjectPreview(projectId);
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
    closeProjectPreview(projectId);
    const state = await projectLifecycle.stop(projectId);
    emitProjectListChanged();
    return state;
  });

  ipcMain.handle('project:restart', async (_event, projectId) => {
    const project = getProjectOrThrow(projectId);
    closeProjectPreview(projectId);
    const state = await projectLifecycle.restart(project);
    emitProjectListChanged();
    return state;
  });

  ipcMain.handle('project:open', (_event, projectId) => {
    const project = getProjectOrThrow(projectId);
    openProject(project);
    return true;
  });

  ipcMain.handle('project:preview', (_event, projectId, bounds) => {
    const project = getProjectOrThrow(projectId);
    return previewProject(project, bounds);
  });

  ipcMain.handle('project:previewResize', (_event, bounds) => resizeProjectPreview(bounds));

  ipcMain.handle('project:previewReload', () => reloadProjectPreview());

  ipcMain.handle('project:previewClose', () => closeProjectPreview());

  ipcMain.handle('project:clearLogs', (_event, projectId) => {
    const state = projectLifecycle.clearLogs(projectId);
    emitProjectListChanged();
    return state;
  });

  ipcMain.handle('project:copyLogs', (_event, projectId) => {
    const state = projectLifecycle.getState(projectId);
    const text = state.logs.join('\n');
    clipboard.writeText(text);
    return {
      copied: state.logs.length,
    };
  });

  ipcMain.handle('project:applyDoctorAction', (_event, projectId, actionId) =>
    applyDoctorAction(projectId, actionId)
  );

  ipcMain.handle('project:copyDoctorReport', (_event, projectId) => {
    const project = getProjectOrThrow(projectId);
    const runtime = serializeRuntime(projectId);
    const text = buildDoctorReport(project, runtime);
    clipboard.writeText(text);
    return {
      copied: true,
      lines: text.split('\n').length - 1,
    };
  });

  ipcMain.handle('project:revealDirectory', async (_event, projectId) => {
    const project = getProjectOrThrow(projectId);
    await revealProjectDirectory(project);
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
    projectLifecycle = new ProjectLifecycle({ openProject, checkPortAvailable, findAvailablePort });
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
