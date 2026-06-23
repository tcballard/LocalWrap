// Tests the real preload.js by mocking electron and capturing the API it
// exposes via contextBridge.

const { version: packageVersion } = require('../package.json');

const mockInvoke = jest.fn(() => Promise.resolve());
const mockSendSync = jest.fn((channel) => (channel === 'app:version' ? packageVersion : undefined));
const mockOn = jest.fn();
const mockRemoveListener = jest.fn();
let exposed;

jest.mock(
  'electron',
  () => ({
    contextBridge: {
      exposeInMainWorld: (key, api) => {
        global.__exposed = { key, api };
      },
    },
    ipcRenderer: {
      invoke: mockInvoke,
      sendSync: mockSendSync,
      on: mockOn,
      removeListener: mockRemoveListener,
    },
  }),
  { virtual: true }
);

beforeAll(() => {
  jest.isolateModules(() => {
    require('../preload');
  });
  exposed = global.__exposed;
});

describe('preload contextBridge API', () => {
  test('exposes localwrapAPI with the expected project surface', () => {
    expect(exposed.key).toBe('localwrapAPI');
    const api = exposed.api;
    expect(api.isElectron).toBe(true);
    expect(api.platform).toBe('desktop');
    // The version is sourced from the main process, never hardcoded in preload.
    expect(mockSendSync).toHaveBeenCalledWith('app:version');
    expect(api.version).toBe(packageVersion);

    for (const method of [
      'listProjects',
      'getWorkspace',
      'diagnoseWorkspace',
      'inspectDirectory',
      'validateProjectDraft',
      'diagnoseProjectDraft',
      'createProject',
      'createSampleProject',
      'updateProject',
      'deleteProject',
      'startProject',
      'stopProject',
      'restartProject',
      'startAllProjects',
      'stopAllProjects',
      'resumeWorkspace',
      'startReadyWorkspace',
      'saveWorkspaceProfile',
      'inspectWorkspacePack',
      'importWorkspacePack',
      'exportWorkspacePack',
      'openProject',
      'previewProject',
      'resizeProjectPreview',
      'reloadProjectPreview',
      'closeProjectPreview',
      'discoverScripts',
      'suggestPort',
      'checkProjectPort',
      'clearProjectLogs',
      'copyProjectLogs',
      'applyDoctorAction',
      'copyDoctorReport',
      'revealProjectDirectory',
      'selectDirectory',
      'onProjectEvent',
      'onProjectListChanged',
      'onPreviewEvent',
    ]) {
      expect(typeof api[method]).toBe('function');
    }
  });

  test('project methods invoke the correct IPC channels', () => {
    mockInvoke.mockClear();

    exposed.api.listProjects();
    expect(mockInvoke).toHaveBeenLastCalledWith('project:list');

    exposed.api.getWorkspace();
    expect(mockInvoke).toHaveBeenLastCalledWith('workspace:get');

    exposed.api.diagnoseWorkspace('workspace-1');
    expect(mockInvoke).toHaveBeenLastCalledWith('workspace:diagnose', 'workspace-1');

    exposed.api.inspectDirectory('/tmp/demo');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:inspectDirectory', '/tmp/demo');

    exposed.api.validateProjectDraft({ name: 'Demo' });
    expect(mockInvoke).toHaveBeenLastCalledWith('project:validateDraft', { name: 'Demo' });

    exposed.api.diagnoseProjectDraft({ name: 'Demo' });
    expect(mockInvoke).toHaveBeenLastCalledWith('project:diagnoseDraft', { name: 'Demo' });

    exposed.api.createProject({ name: 'Demo' });
    expect(mockInvoke).toHaveBeenLastCalledWith('project:create', { name: 'Demo' });

    exposed.api.createSampleProject();
    expect(mockInvoke).toHaveBeenLastCalledWith('project:createSample');

    exposed.api.updateProject('p1', { name: 'Renamed' });
    expect(mockInvoke).toHaveBeenLastCalledWith('project:update', 'p1', { name: 'Renamed' });

    exposed.api.deleteProject('p1');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:delete', 'p1');

    exposed.api.startProject('p1');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:start', 'p1');

    exposed.api.stopProject('p1');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:stop', 'p1');

    exposed.api.restartProject('p1');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:restart', 'p1');

    exposed.api.startAllProjects();
    expect(mockInvoke).toHaveBeenLastCalledWith('project:startAll');

    exposed.api.stopAllProjects();
    expect(mockInvoke).toHaveBeenLastCalledWith('project:stopAll');

    exposed.api.resumeWorkspace('workspace-1');
    expect(mockInvoke).toHaveBeenLastCalledWith('workspace:resume', 'workspace-1');

    exposed.api.startReadyWorkspace('workspace-1');
    expect(mockInvoke).toHaveBeenLastCalledWith('workspace:startReady', 'workspace-1');

    exposed.api.saveWorkspaceProfile({ name: 'Morning stack' });
    expect(mockInvoke).toHaveBeenLastCalledWith('workspace:saveProfile', {
      name: 'Morning stack',
    });

    exposed.api.inspectWorkspacePack('/tmp/repo');
    expect(mockInvoke).toHaveBeenLastCalledWith('workspace:inspectPack', '/tmp/repo');

    exposed.api.importWorkspacePack('/tmp/repo');
    expect(mockInvoke).toHaveBeenLastCalledWith('workspace:importPack', '/tmp/repo');

    exposed.api.exportWorkspacePack('/tmp/repo');
    expect(mockInvoke).toHaveBeenLastCalledWith('workspace:exportPack', '/tmp/repo');

    exposed.api.openProject('p1');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:open', 'p1');

    exposed.api.previewProject('p1', { x: 10, y: 20, width: 300, height: 200 });
    expect(mockInvoke).toHaveBeenLastCalledWith('project:preview', 'p1', {
      x: 10,
      y: 20,
      width: 300,
      height: 200,
    });

    exposed.api.resizeProjectPreview({ x: 12, y: 24, width: 320, height: 220 });
    expect(mockInvoke).toHaveBeenLastCalledWith('project:previewResize', {
      x: 12,
      y: 24,
      width: 320,
      height: 220,
    });

    exposed.api.reloadProjectPreview();
    expect(mockInvoke).toHaveBeenLastCalledWith('project:previewReload');

    exposed.api.closeProjectPreview();
    expect(mockInvoke).toHaveBeenLastCalledWith('project:previewClose');

    exposed.api.discoverScripts('/tmp/demo');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:discoverScripts', '/tmp/demo');

    exposed.api.suggestPort(3000);
    expect(mockInvoke).toHaveBeenLastCalledWith('project:suggestPort', 3000);

    exposed.api.checkProjectPort(3000);
    expect(mockInvoke).toHaveBeenLastCalledWith('project:checkPort', 3000);

    exposed.api.clearProjectLogs('p1');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:clearLogs', 'p1');

    exposed.api.copyProjectLogs('p1');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:copyLogs', 'p1');

    exposed.api.applyDoctorAction('p1', 'sync-url-to-port');
    expect(mockInvoke).toHaveBeenLastCalledWith(
      'project:applyDoctorAction',
      'p1',
      'sync-url-to-port'
    );

    exposed.api.copyDoctorReport('p1');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:copyDoctorReport', 'p1');

    exposed.api.revealProjectDirectory('p1');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:revealDirectory', 'p1');
  });

  test('subscriptions forward payloads and return unsubscribe functions', () => {
    mockOn.mockClear();
    mockRemoveListener.mockClear();
    const cb = jest.fn();
    const unsubscribe = exposed.api.onProjectEvent(cb);
    expect(mockOn).toHaveBeenCalledWith('project:event', expect.any(Function));

    const listener = mockOn.mock.calls[0][1];
    listener({}, { projectId: 'p1', type: 'state' });
    expect(cb).toHaveBeenCalledWith({ projectId: 'p1', type: 'state' });

    unsubscribe();
    expect(mockRemoveListener).toHaveBeenCalledWith('project:event', listener);
  });
});
