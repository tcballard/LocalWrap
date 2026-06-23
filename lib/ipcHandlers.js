'use strict';

const fs = require('fs');
const {
  ACTIONS: DOCTOR_ACTIONS,
  buildDoctorReport,
  diagnoseProjectDraft,
  getDoctorActionPatch,
} = require('./projectDoctor');
const { discoverPackageScripts } = require('./packageScripts');
const { checkPortAvailable, findAvailablePort } = require('./portUtils');
const { inspectProjectDirectory } = require('./projectInspection');
const { validateProjectDraft } = require('./projectValidation');
const { createSampleProject } = require('./sampleProject');
const { validateLocalProjectURL } = require('./urlValidation');
const {
  buildWorkspacePack,
  readWorkspacePack,
  summarizeWorkspacePack,
  writeWorkspacePack,
} = require('./workspacePack');
const { diagnoseWorkspace: diagnoseWorkspaceStack } = require('./workspaceDoctor');

/**
 * Clamp requested preview bounds to the window content area. Pure so the
 * sizing rules can be tested without a BrowserWindow; the caller supplies the
 * window's current content bounds.
 *
 * @throws {Error} when the clamped area is too small to preview anything.
 */
function clampPreviewBounds(bounds = {}, contentBounds) {
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

/**
 * Build the privileged IPC surface. Everything Electron-bound (app, shell,
 * dialog, clipboard, window access, the preview controller) is injected so
 * the handlers can be unit-tested with plain doubles; the Electron-free lib
 * functions are used directly and remain injectable for tests.
 *
 * Returns the channel maps plus the serializers main.js shares with the tray.
 *
 * @param {object} deps
 * @param {Electron.App} deps.app
 * @param {Electron.Clipboard} deps.clipboard
 * @param {Electron.Dialog} deps.dialog
 * @param {Electron.Shell} deps.shell
 * @param {import('./projectStore').ProjectStore} deps.projectStore
 * @param {import('./projectLifecycle').ProjectLifecycle} deps.projectLifecycle
 * @param {() => void} deps.emitProjectListChanged
 * @param {() => Electron.BrowserWindow|null} deps.getMainWindow
 * @param {(project: object) => void} deps.openProject
 * @param {{open: Function, resize: Function, reload: Function, close: Function}} deps.preview
 * @param {string} deps.appRoot
 * @param {string} [deps.resourcesPath]
 */
function createIpcHandlers(deps) {
  const {
    app,
    clipboard,
    dialog,
    shell,
    projectStore,
    projectLifecycle,
    emitProjectListChanged,
    getMainWindow,
    openProject,
    preview,
    appRoot,
    resourcesPath,
    fsImpl = fs,
    checkPortAvailable: checkPort = checkPortAvailable,
    findAvailablePort: findPort = findAvailablePort,
    createSampleProject: createSample = createSampleProject,
    persistActiveWorkspaceSnapshot = () => projectStore.getWorkspace(),
  } = deps;

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

  function getProjectOrThrow(projectId) {
    const project = projectStore.get(projectId);
    if (!project) {
      throw new Error('Project not found.');
    }
    return project;
  }

  function revealProjectDirectory(project) {
    if (!fsImpl.existsSync(project.cwd) || !fsImpl.statSync(project.cwd).isDirectory()) {
      throw new Error('Project directory does not exist.');
    }
    return shell.openPath(project.cwd);
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
      const port = await findPort(project.port);
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

  async function startProjects(projects, options = {}) {
    const results = await projectLifecycle.startAll(projects);
    if (options.workspaceProfileId) {
      projectStore.markWorkspaceProfileStarted(options.workspaceProfileId);
    }
    persistActiveWorkspaceSnapshot();
    emitProjectListChanged();
    return {
      results,
      workspace: serializeWorkspace(),
      projects: serializeProjects(),
    };
  }

  function workspaceTargetProfileId(profileId, diagnosis = null) {
    if (profileId && diagnosis?.target?.kind === 'profile') {
      return profileId;
    }
    return null;
  }

  async function startAllProjects() {
    return startProjects(projectStore.list());
  }

  function projectsForIds(projectIds = []) {
    return projectIds.map((projectId) => projectStore.get(projectId)).filter(Boolean);
  }

  async function resumeWorkspaceProjects(profileId = null) {
    const workspace = serializeWorkspace();
    const profile = profileId
      ? workspace.savedWorkspaces.find((candidate) => candidate.id === profileId)
      : null;
    if (profileId && !profile) {
      throw new Error('Workspace not found.');
    }

    const projectIds = profile ? profile.projectIds : workspace.lastRunningProjectIds;
    return startProjects(projectsForIds(projectIds), {
      workspaceProfileId: profile?.id || null,
    });
  }

  async function diagnoseWorkspace(profileId = null) {
    return diagnoseWorkspaceStack(
      {
        projects: projectStore.list(),
        workspace: serializeWorkspace(),
        profileId,
      },
      {
        fsImpl,
        checkPortAvailable: checkPort,
      }
    );
  }

  async function startReadyWorkspace(profileId = null) {
    const diagnosis = await diagnoseWorkspace(profileId);
    if (diagnosis.startableProjectIds.length === 0) {
      throw new Error('No ready workspace projects to start.');
    }

    const result = await startProjects(projectsForIds(diagnosis.startableProjectIds), {
      workspaceProfileId: workspaceTargetProfileId(profileId, diagnosis),
    });
    return {
      ...result,
      diagnosis,
      skippedBlockedProjectIds: diagnosis.blockedProjectIds,
    };
  }

  function saveWorkspaceProfile(input = {}) {
    const activeProjectIds = projectLifecycle.getActiveProjectIds();
    const fallbackIds = serializeWorkspace().lastRunningProjectIds || [];
    const projectIds =
      Array.isArray(input.projectIds) && input.projectIds.length > 0
        ? input.projectIds
        : activeProjectIds.length > 0
          ? activeProjectIds
          : fallbackIds;
    const profile = projectStore.saveWorkspaceProfile({
      ...input,
      projectIds,
    });
    emitProjectListChanged();
    return {
      profile,
      workspace: serializeWorkspace(),
    };
  }

  function readPackForDirectory(rootDir) {
    return readWorkspacePack(rootDir, { fsImpl });
  }

  function inspectWorkspacePack(rootDir) {
    return summarizeWorkspacePack(readPackForDirectory(rootDir));
  }

  function importWorkspacePack(rootDir) {
    const pack = readPackForDirectory(rootDir);
    const result = projectStore.importWorkspacePack(pack);
    emitProjectListChanged();
    return {
      ...result,
      summary: summarizeWorkspacePack(pack),
      workspace: serializeWorkspace(),
      projects: serializeProjects(),
    };
  }

  function exportWorkspacePack(rootDir) {
    const { pack, skippedProjects } = buildWorkspacePack({
      rootDir,
      projects: projectStore.list(),
      workspace: projectStore.getWorkspace(),
    });
    const packPath = writeWorkspacePack(rootDir, pack, { fsImpl });
    return {
      packPath,
      name: pack.name,
      projectCount: pack.projects.length,
      workspaceCount: pack.workspaces.length,
      skippedProjects,
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

  const invokeHandlers = {
    'project:list': () => serializeProjects(),

    'workspace:get': () => serializeWorkspace(),

    'workspace:diagnose': (_event, profileId = null) => diagnoseWorkspace(profileId),

    'project:inspectDirectory': (_event, cwd) =>
      inspectProjectDirectory(cwd, {
        findAvailablePort: findPort,
      }),

    'project:validateDraft': (_event, draft) =>
      validateProjectDraft(draft, {
        checkPortAvailable: checkPort,
      }),

    'project:diagnoseDraft': (_event, draft) =>
      diagnoseProjectDraft(draft, {
        checkPortAvailable: checkPort,
        findAvailablePort: findPort,
      }),

    'project:create': async (_event, payload = {}) => {
      const project = projectStore.create(payload);
      emitProjectListChanged();

      if (project.autostart) {
        projectLifecycle.start(project).catch((error) => console.error('Autostart failed:', error));
      }

      return serializeProject(project);
    },

    'project:createSample': async () => {
      const project = await createSample({
        app,
        appRoot,
        findAvailablePort: findPort,
        inspectProjectDirectory,
        projectStore,
        resourcesPath,
      });
      emitProjectListChanged();
      return serializeProject(project);
    },

    'project:suggestPort': (_event, preferredPort = 3000) => findPort(preferredPort),

    'project:checkPort': async (_event, port) => ({
      port,
      available: await checkPort(port),
    }),

    'project:update': (_event, projectId, patch = {}) => {
      assertSafeProjectMutation(projectId, patch);
      const project = projectStore.update(projectId, patch);
      emitProjectListChanged();
      return serializeProject(project);
    },

    'project:delete': async (_event, projectId) => {
      preview.close(projectId);
      await projectLifecycle.stop(projectId);
      projectStore.delete(projectId);
      emitProjectListChanged();
      return true;
    },

    'project:start': async (_event, projectId) => {
      const project = getProjectOrThrow(projectId);
      const state = await projectLifecycle.start(project);
      persistActiveWorkspaceSnapshot();
      emitProjectListChanged();
      return state;
    },

    'project:stop': async (_event, projectId) => {
      preview.close(projectId);
      persistActiveWorkspaceSnapshot();
      const state = await projectLifecycle.stop(projectId);
      emitProjectListChanged();
      return state;
    },

    'project:restart': async (_event, projectId) => {
      const project = getProjectOrThrow(projectId);
      preview.close(projectId);
      persistActiveWorkspaceSnapshot();
      const state = await projectLifecycle.restart(project);
      emitProjectListChanged();
      return state;
    },

    'project:startAll': () => startAllProjects(),

    'project:stopAll': () => stopAllProjects(),

    'workspace:resume': (_event, profileId = null) => resumeWorkspaceProjects(profileId),

    'workspace:startReady': (_event, profileId = null) => startReadyWorkspace(profileId),

    'workspace:saveProfile': (_event, input = {}) => saveWorkspaceProfile(input),

    'workspace:inspectPack': (_event, rootDir) => inspectWorkspacePack(rootDir),

    'workspace:importPack': (_event, rootDir) => importWorkspacePack(rootDir),

    'workspace:exportPack': (_event, rootDir) => exportWorkspacePack(rootDir),

    'project:open': (_event, projectId) => {
      const project = getProjectOrThrow(projectId);
      openProject(project);
      return true;
    },

    'project:preview': (_event, projectId, bounds) => {
      const project = getProjectOrThrow(projectId);
      if (!validateLocalProjectURL(project.url)) {
        throw new Error('Project URL must be local.');
      }

      const runtime = serializeRuntime(project.id);
      if (runtime.status !== 'ready') {
        throw new Error('Project must be ready before previewing it in LocalWrap.');
      }

      return preview.open(project, bounds);
    },

    'project:previewResize': (_event, bounds) => preview.resize(bounds),

    'project:previewReload': () => preview.reload(),

    'project:previewClose': () => preview.close(),

    'project:clearLogs': (_event, projectId) => {
      const state = projectLifecycle.clearLogs(projectId);
      emitProjectListChanged();
      return state;
    },

    'project:copyLogs': (_event, projectId) => {
      const state = projectLifecycle.getState(projectId);
      const text = state.logs.join('\n');
      clipboard.writeText(text);
      return {
        copied: state.logs.length,
      };
    },

    'project:applyDoctorAction': (_event, projectId, actionId) =>
      applyDoctorAction(projectId, actionId),

    'project:copyDoctorReport': (_event, projectId) => {
      const project = getProjectOrThrow(projectId);
      const runtime = serializeRuntime(projectId);
      const text = buildDoctorReport(project, runtime);
      clipboard.writeText(text);
      return {
        copied: true,
        lines: text.split('\n').length - 1,
      };
    },

    'project:revealDirectory': async (_event, projectId) => {
      const project = getProjectOrThrow(projectId);
      await revealProjectDirectory(project);
      return true;
    },

    'project:discoverScripts': (_event, cwd) => discoverPackageScripts(cwd),

    'dir:select': async () => {
      const result = await dialog.showOpenDialog(getMainWindow(), {
        title: 'Select project directory',
        properties: ['openDirectory'],
      });

      if (result.canceled || result.filePaths.length === 0) {
        return null;
      }

      return result.filePaths[0];
    },
  };

  // Registered with ipcMain.on + event.returnValue: the sandboxed preload
  // reads these synchronously while building its API.
  const syncHandlers = {
    'app:version': () => app.getVersion(),
  };

  return {
    applyDoctorAction,
    assertSafeProjectMutation,
    invokeHandlers,
    resumeWorkspaceProjects,
    saveWorkspaceProfile,
    serializeProject,
    serializeProjects,
    serializeWorkspace,
    serializeRuntime,
    startAllProjects,
    stopAllProjects,
    syncHandlers,
  };
}

module.exports = { clampPreviewBounds, createIpcHandlers };
