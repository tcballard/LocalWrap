const { EventEmitter } = require('events');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { clampPreviewBounds, createIpcHandlers } = require('../lib/ipcHandlers');
const { ProjectLifecycle } = require('../lib/projectLifecycle');
const { ProjectStore } = require('../lib/projectStore');

function createFakeChild(pid = 1234) {
  const child = new EventEmitter();
  child.pid = pid;
  child.kill = jest.fn(() => true);
  return child;
}

describe('clampPreviewBounds', () => {
  const contentBounds = { width: 1000, height: 700 };

  test('floors and clamps bounds to the window content area', () => {
    expect(
      clampPreviewBounds({ x: 10.9, y: -5, width: 2000, height: 650.7 }, contentBounds)
    ).toEqual({
      x: 10,
      y: 0,
      width: 990,
      height: 650,
    });
  });

  test('rejects areas that are too small to preview', () => {
    expect(() =>
      clampPreviewBounds({ x: 0, y: 0, width: 119, height: 600 }, contentBounds)
    ).toThrow(/too small/);
    expect(() =>
      clampPreviewBounds({ x: 950, y: 0, width: 400, height: 600 }, contentBounds)
    ).toThrow(/too small/);
    expect(() => clampPreviewBounds({}, contentBounds)).toThrow(/too small/);
  });
});

describe('createIpcHandlers', () => {
  let fixture;

  beforeEach(() => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-ipc-'));
    const cwd = path.join(root, 'demo-app');
    fs.mkdirSync(cwd);

    const projectStore = new ProjectStore({
      filePath: path.join(root, 'projects.json'),
    });
    const child = createFakeChild();
    const projectLifecycle = new ProjectLifecycle({
      startScript: jest.fn(() => child),
      waitForReady: jest.fn(() => Promise.resolve(true)),
      killProcessTree: jest.fn(async () => {
        child.emit('close', 0);
        return true;
      }),
    });

    fixture = {
      root,
      cwd,
      child,
      projectStore,
      projectLifecycle,
      app: { getVersion: jest.fn(() => '9.9.9') },
      clipboard: { writeText: jest.fn() },
      dialog: { showOpenDialog: jest.fn() },
      shell: { openExternal: jest.fn(), openPath: jest.fn(async () => '') },
      openProject: jest.fn(),
      emitProjectListChanged: jest.fn(),
      preview: {
        open: jest.fn(() => ({ ok: true })),
        resize: jest.fn(() => true),
        reload: jest.fn(() => true),
        close: jest.fn(() => true),
      },
      mainWindow: { id: 'main-window' },
    };
  });

  afterEach(() => {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  });

  function createHandlers(overrides = {}) {
    const ipc = createIpcHandlers({
      app: fixture.app,
      clipboard: fixture.clipboard,
      dialog: fixture.dialog,
      shell: fixture.shell,
      projectStore: fixture.projectStore,
      projectLifecycle: fixture.projectLifecycle,
      emitProjectListChanged: fixture.emitProjectListChanged,
      getMainWindow: () => fixture.mainWindow,
      openProject: fixture.openProject,
      preview: fixture.preview,
      appRoot: path.join(__dirname, '..'),
      checkPortAvailable: jest.fn(async () => true),
      findAvailablePort: jest.fn(async () => 4567),
      ...overrides,
    });
    // Async so synchronous handler throws become rejections, matching how
    // ipcMain.handle surfaces them to the renderer.
    const invoke = async (channel, ...args) => ipc.invokeHandlers[channel]({}, ...args);
    return { ipc, invoke };
  }

  function projectInput(overrides = {}) {
    return {
      name: 'Demo',
      cwd: fixture.cwd,
      command: 'npm run dev',
      port: 5173,
      url: 'http://localhost:5173',
      ...overrides,
    };
  }

  async function createSavedProject(invoke, overrides = {}) {
    return invoke('project:create', projectInput(overrides));
  }

  async function startedProject(invoke, overrides = {}) {
    const project = await createSavedProject(invoke, overrides);
    await invoke('project:start', project.id);
    await new Promise((resolve) => setImmediate(resolve)); // let readiness settle
    return project;
  }

  test('app:version is served synchronously from the app', () => {
    const { ipc } = createHandlers();
    expect(ipc.syncHandlers['app:version']()).toBe('9.9.9');
  });

  test('project:create persists, emits, and returns runtime state', async () => {
    const { invoke } = createHandlers();
    const project = await createSavedProject(invoke);

    expect(project).toMatchObject({
      name: 'Demo',
      port: 5173,
      runtime: { status: 'stopped' },
    });
    expect(fixture.emitProjectListChanged).toHaveBeenCalled();
    expect(await invoke('project:list')).toHaveLength(1);
  });

  test('project:create autostarts when requested', async () => {
    const { invoke } = createHandlers();
    const startSpy = jest.spyOn(fixture.projectLifecycle, 'start');

    await createSavedProject(invoke, { autostart: true });
    await new Promise((resolve) => setImmediate(resolve));

    expect(startSpy).toHaveBeenCalledWith(expect.objectContaining({ name: 'Demo' }));
  });

  test('project:update refuses launch-config changes while the project runs', async () => {
    const { invoke } = createHandlers();
    const project = await startedProject(invoke);

    await expect(invoke('project:update', project.id, { port: 6001 })).rejects.toThrow(
      /Stop the project before changing/
    );

    // Cosmetic fields stay editable while running.
    const renamed = await invoke('project:update', project.id, { name: 'Renamed' });
    expect(renamed.name).toBe('Renamed');
  });

  test('project:stop closes the preview for that project and stops the process', async () => {
    const { invoke } = createHandlers();
    const project = await startedProject(invoke);

    const state = await invoke('project:stop', project.id);

    expect(fixture.preview.close).toHaveBeenCalledWith(project.id);
    expect(state.status).toBe('stopped');
  });

  test('project:delete stops the project, closes its preview, and removes it', async () => {
    const { invoke } = createHandlers();
    const project = await startedProject(invoke);

    await invoke('project:delete', project.id);

    expect(fixture.preview.close).toHaveBeenCalledWith(project.id);
    expect(fixture.projectStore.list()).toHaveLength(0);
    expect(fixture.projectLifecycle.getState(project.id).status).toBe('stopped');
  });

  test('project:open delegates to the injected opener', async () => {
    const { invoke } = createHandlers();
    const project = await createSavedProject(invoke);

    await invoke('project:open', project.id);

    expect(fixture.openProject).toHaveBeenCalledWith(expect.objectContaining({ id: project.id }));
  });

  test('project:open rejects unknown projects', async () => {
    const { invoke } = createHandlers();
    await expect(invoke('project:open', 'nope')).rejects.toThrow(/not found/);
  });

  test('project:preview requires a ready project', async () => {
    const { invoke } = createHandlers();
    const project = await createSavedProject(invoke);

    await expect(
      invoke('project:preview', project.id, { width: 400, height: 300 })
    ).rejects.toThrow(/must be ready/);
    expect(fixture.preview.open).not.toHaveBeenCalled();
  });

  test('project:preview opens the preview once the project is ready', async () => {
    const { invoke } = createHandlers();
    const project = await startedProject(invoke);
    const bounds = { x: 1, y: 2, width: 400, height: 300 };

    await invoke('project:preview', project.id, bounds);

    expect(fixture.preview.open).toHaveBeenCalledWith(
      expect.objectContaining({ id: project.id }),
      bounds
    );
  });

  test('preview resize, reload, and close pass through to the controller', async () => {
    const { invoke } = createHandlers();

    await invoke('project:previewResize', { width: 300, height: 200 });
    await invoke('project:previewReload');
    await invoke('project:previewClose');

    expect(fixture.preview.resize).toHaveBeenCalledWith({ width: 300, height: 200 });
    expect(fixture.preview.reload).toHaveBeenCalled();
    expect(fixture.preview.close).toHaveBeenCalledWith();
  });

  test('project:copyLogs copies the runtime log to the clipboard', async () => {
    const { invoke } = createHandlers();
    const project = await startedProject(invoke);
    fixture.projectLifecycle.appendLog(project.id, 'line one');

    const result = await invoke('project:copyLogs', project.id);

    expect(fixture.clipboard.writeText).toHaveBeenCalledWith(expect.stringContaining('line one'));
    expect(result.copied).toBeGreaterThan(0);
  });

  test('project:copyDoctorReport copies a full report', async () => {
    const { invoke } = createHandlers();
    const project = await createSavedProject(invoke);

    const result = await invoke('project:copyDoctorReport', project.id);

    expect(result.copied).toBe(true);
    expect(fixture.clipboard.writeText).toHaveBeenCalledWith(
      expect.stringContaining('LocalWrap Doctor Report')
    );
  });

  test('applyDoctorAction use-free-port patches port and synced URL', async () => {
    const { invoke } = createHandlers();
    const project = await createSavedProject(invoke);

    const updated = await invoke('project:applyDoctorAction', project.id, 'use-free-port');

    expect(updated.port).toBe(4567);
    expect(updated.url).toBe('http://localhost:4567');
    expect(fixture.projectStore.get(project.id).port).toBe(4567);
  });

  test('applyDoctorAction sync-url-to-port aligns the URL', async () => {
    const { invoke } = createHandlers();
    const project = await createSavedProject(invoke, { url: 'http://localhost:5999' });

    const updated = await invoke('project:applyDoctorAction', project.id, 'sync-url-to-port');

    expect(updated.url).toBe('http://localhost:5173');
  });

  test('applyDoctorAction reveal-directory opens the project folder', async () => {
    const { invoke } = createHandlers();
    const project = await createSavedProject(invoke);

    await invoke('project:applyDoctorAction', project.id, 'reveal-directory');

    expect(fixture.shell.openPath).toHaveBeenCalledWith(fixture.cwd);
  });

  test('applyDoctorAction rejects unknown actions', async () => {
    const { invoke } = createHandlers();
    const project = await createSavedProject(invoke);

    await expect(invoke('project:applyDoctorAction', project.id, 'rm-rf')).rejects.toThrow(
      /Unknown Project Doctor action/
    );
  });

  test('mutating doctor actions are blocked while the project runs', async () => {
    const { invoke } = createHandlers();
    const project = await startedProject(invoke);

    await expect(invoke('project:applyDoctorAction', project.id, 'use-free-port')).rejects.toThrow(
      /Stop the project before changing/
    );
  });

  test('project:revealDirectory rejects a missing directory', async () => {
    const { invoke } = createHandlers();
    const project = await createSavedProject(invoke);
    fs.rmSync(fixture.cwd, { recursive: true, force: true });

    await expect(invoke('project:revealDirectory', project.id)).rejects.toThrow(/does not exist/);
  });

  test('project:checkPort and project:suggestPort use the injected port helpers', async () => {
    const { invoke } = createHandlers();

    expect(await invoke('project:checkPort', 5173)).toEqual({ port: 5173, available: true });
    expect(await invoke('project:suggestPort', 3000)).toBe(4567);
  });

  test('dir:select returns the chosen path and null on cancel', async () => {
    const { invoke } = createHandlers();
    fixture.dialog.showOpenDialog
      .mockResolvedValueOnce({ canceled: false, filePaths: ['/tmp/picked'] })
      .mockResolvedValueOnce({ canceled: true, filePaths: [] });

    expect(await invoke('dir:select')).toBe('/tmp/picked');
    expect(fixture.dialog.showOpenDialog).toHaveBeenCalledWith(
      fixture.mainWindow,
      expect.objectContaining({ properties: ['openDirectory'] })
    );
    expect(await invoke('dir:select')).toBeNull();
  });

  test('project:discoverScripts and project:inspectDirectory read the real directory', async () => {
    const { invoke } = createHandlers();
    fs.writeFileSync(
      path.join(fixture.cwd, 'package.json'),
      JSON.stringify({ name: 'demo-app', scripts: { dev: 'node server.js' } })
    );

    const scripts = await invoke('project:discoverScripts', fixture.cwd);
    expect(scripts.map((script) => script.command)).toEqual(['npm run dev']);

    const profile = await invoke('project:inspectDirectory', fixture.cwd);
    expect(profile).toMatchObject({
      name: 'demo-app',
      recommendedCommand: 'npm run dev',
      suggestedPort: 4567,
    });
  });

  test('project:validateDraft and project:diagnoseDraft wire the port helpers through', async () => {
    const { invoke } = createHandlers();

    const validation = await invoke('project:validateDraft', projectInput());
    expect(validation.valid).toBe(true);

    const diagnosis = await invoke('project:diagnoseDraft', projectInput());
    expect(diagnosis.status).toBe('idle');
    expect(diagnosis.validation.valid).toBe(true);
  });
});
