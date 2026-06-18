'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  app,
  BrowserView,
  BrowserWindow,
  clipboard,
  desktopCapturer,
  ipcMain,
  shell,
} = require('electron');
const { discoverPackageScripts } = require('../lib/packageScripts');
const { checkPortAvailable, findAvailablePort } = require('../lib/portUtils');
const {
  ACTIONS: DOCTOR_ACTIONS,
  buildDoctorReport,
  diagnoseProjectDraft,
  getDoctorActionPatch,
} = require('../lib/projectDoctor');
const { inspectProjectDirectory } = require('../lib/projectInspection');
const { ProjectLifecycle } = require('../lib/projectLifecycle');
const { ProjectStore } = require('../lib/projectStore');
const { createSampleProject } = require('../lib/sampleProject');
const { validateProjectDraft } = require('../lib/projectValidation');
const { validateLocalProjectURL } = require('../lib/urlValidation');
const { version } = require('../package.json');

const repoRoot = path.join(__dirname, '..');
const screenshotsDir = path.join(repoRoot, 'assets', 'screenshots', 'v3');
const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-v3-screenshots-'));

let mainWindow;
let previewView;
let previewProjectId;
let projectStore;
let projectLifecycle;
let lastPersistedWorkspaceKey = '';

app.setName('LocalWrap Screenshot Harness');
app.setPath('userData', userDataDir);

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(predicate, label, timeoutMs = 15000) {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    if (await predicate()) {
      return;
    }
    await delay(100);
  }
  throw new Error(`Timed out waiting for ${label}.`);
}

function serializeRuntime(projectId) {
  return projectLifecycle
    ? projectLifecycle.getState(projectId)
    : { status: 'stopped', logs: [], diagnosis: null };
}

function serializeProject(project) {
  return {
    ...project,
    runtime: serializeRuntime(project.id),
  };
}

function serializeProjects() {
  return projectStore.list().map(serializeProject);
}

function serializeWorkspace() {
  return projectStore.getWorkspace();
}

function sendToRenderer(channel, payload) {
  if (mainWindow && !mainWindow.isDestroyed()) {
    mainWindow.webContents.send(channel, payload);
  }
}

function emitProjectListChanged() {
  sendToRenderer('project:list-changed', serializeProjects());
}

function getProjectOrThrow(projectId) {
  const project = projectStore.get(projectId);
  if (!project) {
    throw new Error('Project not found.');
  }
  return project;
}

function persistActiveWorkspaceSnapshot() {
  const activeProjectIds = projectLifecycle.getActiveProjectIds();
  if (activeProjectIds.length === 0) {
    return serializeWorkspace();
  }

  const key = activeProjectIds.join('\0');
  if (key === lastPersistedWorkspaceKey) {
    return serializeWorkspace();
  }

  lastPersistedWorkspaceKey = key;
  return projectStore.setLastRunningProjectIds(activeProjectIds);
}

async function startProjects(projects) {
  const results = await projectLifecycle.startAll(projects);
  persistActiveWorkspaceSnapshot();
  emitProjectListChanged();
  return {
    results,
    workspace: serializeWorkspace(),
    projects: serializeProjects(),
  };
}

async function stopAllProjects() {
  persistActiveWorkspaceSnapshot();
  const states = await projectLifecycle.stopAll();
  emitProjectListChanged();
  return {
    states,
    workspace: serializeWorkspace(),
    projects: serializeProjects(),
  };
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

  view.webContents.on('did-start-loading', () => {
    sendToRenderer('preview:event', { projectId: previewProjectId, status: 'loading' });
  });
  view.webContents.on('did-finish-load', () => {
    sendToRenderer('preview:event', {
      projectId: previewProjectId,
      status: 'ready',
      url: view.webContents.getURL(),
    });
  });
  view.webContents.on('did-fail-load', (_event, _code, message, validatedURL) => {
    sendToRenderer('preview:event', {
      projectId: previewProjectId,
      status: 'failed',
      url: validatedURL,
      message,
    });
  });

  return view;
}

function normalizePreviewBounds(bounds = {}) {
  const contentBounds = mainWindow.getContentBounds();
  const x = Math.max(0, Math.floor(Number(bounds.x) || 0));
  const y = Math.max(0, Math.floor(Number(bounds.y) || 0));
  const width = Math.floor(Number(bounds.width) || 0);
  const height = Math.floor(Number(bounds.height) || 0);
  return {
    x,
    y,
    width: Math.max(120, Math.min(width, contentBounds.width - x)),
    height: Math.max(80, Math.min(height, contentBounds.height - y)),
  };
}

function previewProject(project, bounds) {
  if (!validateLocalProjectURL(project.url)) {
    throw new Error('Project URL must be local.');
  }

  if (serializeRuntime(project.id).status !== 'ready') {
    throw new Error('Project must be ready before previewing it in LocalWrap.');
  }

  if (!previewView || previewView.webContents.isDestroyed()) {
    previewView = createPreviewView();
  }

  previewProjectId = project.id;
  mainWindow.setBrowserView(previewView);
  previewView.setBounds(normalizePreviewBounds(bounds));
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

function registerIpcHandlers() {
  ipcMain.on('app:version', (event) => {
    event.returnValue = version;
  });

  ipcMain.handle('project:list', () => serializeProjects());
  ipcMain.handle('workspace:get', () => serializeWorkspace());
  ipcMain.handle('project:inspectDirectory', (_event, cwd) =>
    inspectProjectDirectory(cwd, { findAvailablePort })
  );
  ipcMain.handle('project:validateDraft', (_event, draft) =>
    validateProjectDraft(draft, { checkPortAvailable })
  );
  ipcMain.handle('project:diagnoseDraft', (_event, draft) =>
    diagnoseProjectDraft(draft, { checkPortAvailable, findAvailablePort })
  );
  ipcMain.handle('project:create', (_event, payload = {}) => {
    const project = projectStore.create(payload);
    emitProjectListChanged();
    return serializeProject(project);
  });
  ipcMain.handle('project:createSample', async () => {
    const project = await createSampleProject({
      app,
      appRoot: repoRoot,
      findAvailablePort,
      inspectProjectDirectory,
      projectStore,
      resourcesPath: process.resourcesPath,
    });
    emitProjectListChanged();
    return serializeProject(project);
  });
  ipcMain.handle('project:update', (_event, projectId, patch = {}) => {
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
    persistActiveWorkspaceSnapshot();
    const state = await projectLifecycle.stop(projectId);
    emitProjectListChanged();
    return state;
  });
  ipcMain.handle('project:restart', async (_event, projectId) => {
    const project = getProjectOrThrow(projectId);
    closeProjectPreview(projectId);
    persistActiveWorkspaceSnapshot();
    const state = await projectLifecycle.restart(project);
    emitProjectListChanged();
    return state;
  });
  ipcMain.handle('project:startAll', () => startProjects(projectStore.list()));
  ipcMain.handle('project:stopAll', () => stopAllProjects());
  ipcMain.handle('workspace:resume', () => {
    const projects = serializeWorkspace()
      .lastRunningProjectIds.map((projectId) => projectStore.get(projectId))
      .filter(Boolean);
    return startProjects(projects);
  });
  ipcMain.handle('project:open', (_event, projectId) => {
    const project = getProjectOrThrow(projectId);
    return shell.openExternal(project.url);
  });
  ipcMain.handle('project:preview', (_event, projectId, bounds) =>
    previewProject(getProjectOrThrow(projectId), bounds)
  );
  ipcMain.handle('project:previewResize', (_event, bounds) => resizeProjectPreview(bounds));
  ipcMain.handle('project:previewReload', () => {
    if (!previewView || previewView.webContents.isDestroyed()) return false;
    previewView.webContents.reloadIgnoringCache();
    return true;
  });
  ipcMain.handle('project:previewClose', () => closeProjectPreview());
  ipcMain.handle('project:discoverScripts', (_event, cwd) => discoverPackageScripts(cwd));
  ipcMain.handle('project:suggestPort', (_event, preferredPort = 3000) =>
    findAvailablePort(preferredPort)
  );
  ipcMain.handle('project:checkPort', async (_event, port) => ({
    port,
    available: await checkPortAvailable(port),
  }));
  ipcMain.handle('project:clearLogs', (_event, projectId) => projectLifecycle.clearLogs(projectId));
  ipcMain.handle('project:copyLogs', (_event, projectId) => {
    const state = projectLifecycle.getState(projectId);
    clipboard.writeText(state.logs.join('\n'));
    return { copied: state.logs.length };
  });
  ipcMain.handle('project:applyDoctorAction', (_event, projectId, actionId) => {
    const project = getProjectOrThrow(projectId);
    const patch =
      actionId === DOCTOR_ACTIONS.USE_FREE_PORT
        ? getDoctorActionPatch(project, actionId, { port: project.port + 1 })
        : getDoctorActionPatch(project, actionId);
    return serializeProject(projectStore.update(projectId, patch));
  });
  ipcMain.handle('project:copyDoctorReport', (_event, projectId) => {
    const project = getProjectOrThrow(projectId);
    clipboard.writeText(buildDoctorReport(project, serializeRuntime(projectId)));
    return { copied: true, lines: clipboard.readText().split('\n').length - 1 };
  });
  ipcMain.handle('project:revealDirectory', () => true);
  ipcMain.handle('dir:select', () => null);
  ipcMain.handle('dir:current', () => repoRoot);
}

async function capture(name) {
  await delay(350);
  const bounds = mainWindow.getBounds();
  const sources = await desktopCapturer.getSources({
    types: ['window'],
    thumbnailSize: {
      width: bounds.width,
      height: bounds.height,
    },
  });
  const source = sources.find((item) => item.name.includes('LocalWrap'));
  const image =
    source && !source.thumbnail.isEmpty() ? source.thumbnail : await mainWindow.capturePage();
  const filePath = path.join(screenshotsDir, `${name}.png`);
  fs.writeFileSync(filePath, image.toPNG());
  console.log(filePath);
}

async function click(id) {
  await mainWindow.webContents.executeJavaScript(
    `document.getElementById(${JSON.stringify(id)}).click()`
  );
}

async function elementEnabled(id) {
  return mainWindow.webContents.executeJavaScript(
    `Boolean(document.getElementById(${JSON.stringify(id)}) && !document.getElementById(${JSON.stringify(
      id
    )}).disabled)`
  );
}

function selectedProject() {
  return projectStore.list()[0] || null;
}

async function runGoldenPath() {
  fs.mkdirSync(screenshotsDir, { recursive: true });
  await waitFor(() => elementEnabled('emptySampleProjectBtn'), 'empty sample button');
  await capture('01-empty-state');

  await click('emptySampleProjectBtn');
  await waitFor(() => projectStore.list().length === 1, 'sample project creation');
  await waitFor(() => elementEnabled('saveAndStartBtn'), 'Save & Start button');
  await capture('02-sample-configured');

  await click('saveAndStartBtn');
  const sample = selectedProject();
  await waitFor(() => projectLifecycle.getState(sample.id).status === 'starting', 'starting state');
  await capture('03-starting-doctor');

  await waitFor(() => projectLifecycle.getState(sample.id).status === 'ready', 'ready state');
  await capture('04-ready');

  await waitFor(() => elementEnabled('previewProjectBtn'), 'preview button');
  await click('previewProjectBtn');
  await waitFor(
    () =>
      mainWindow.webContents.executeJavaScript(
        "document.getElementById('previewPanel') && !document.getElementById('previewPanel').hidden"
      ),
    'visible preview panel'
  );
  await waitFor(
    () =>
      mainWindow.webContents.executeJavaScript(
        "document.getElementById('previewPlaceholder') && document.getElementById('previewPlaceholder').hidden"
      ),
    'ready preview'
  );
  await capture('05-previewing');

  await click('stopProjectBtn');
  await waitFor(() => projectLifecycle.getState(sample.id).status === 'stopped', 'stopped state');
  await waitFor(() => elementEnabled('resumeWorkspaceBtn'), 'resume workspace button');
  await capture('06-stopped-resume-available');

  await click('resumeWorkspaceBtn');
  await waitFor(() => projectLifecycle.getState(sample.id).status === 'ready', 'resumed ready');
  await capture('07-resumed-ready');
}

app.whenReady().then(async () => {
  try {
    projectStore = new ProjectStore({
      filePath: path.join(app.getPath('userData'), 'projects.json'),
    });
    projectLifecycle = new ProjectLifecycle({ checkPortAvailable, findAvailablePort });
    projectLifecycle.on('event', (event) => {
      sendToRenderer('project:event', event);
      if (event.type === 'state') {
        persistActiveWorkspaceSnapshot();
      }
    });

    registerIpcHandlers();

    mainWindow = new BrowserWindow({
      width: 1280,
      height: 860,
      minWidth: 860,
      minHeight: 620,
      show: false,
      backgroundColor: '#f0f0f0',
      webPreferences: {
        nodeIntegration: false,
        contextIsolation: true,
        preload: path.join(repoRoot, 'preload.js'),
        webSecurity: true,
        allowRunningInsecureContent: false,
        sandbox: true,
      },
    });

    mainWindow.setTitle('LocalWrap - v3 Screenshot Harness');
    await mainWindow.loadFile(path.join(repoRoot, 'public', 'app.html'));
    mainWindow.show();
    await delay(750);
    await runGoldenPath();
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  } finally {
    closeProjectPreview();
    if (projectLifecycle) {
      await projectLifecycle.stopAll();
    }
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.close();
    }
    app.quit();
  }
});
