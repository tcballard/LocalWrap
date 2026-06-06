// Tests the real preload.js by mocking electron and capturing the API it
// exposes via contextBridge.

const mockInvoke = jest.fn(() => Promise.resolve());
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
    expect(api.version).toBe('2.4.0');

    for (const method of [
      'listProjects',
      'inspectDirectory',
      'validateProjectDraft',
      'createProject',
      'updateProject',
      'deleteProject',
      'startProject',
      'stopProject',
      'restartProject',
      'openProject',
      'discoverScripts',
      'suggestPort',
      'checkProjectPort',
      'clearProjectLogs',
      'copyProjectLogs',
      'selectDirectory',
      'getCurrentDirectory',
      'onProjectEvent',
      'onProjectListChanged',
    ]) {
      expect(typeof api[method]).toBe('function');
    }
  });

  test('project methods invoke the correct IPC channels', () => {
    mockInvoke.mockClear();

    exposed.api.listProjects();
    expect(mockInvoke).toHaveBeenLastCalledWith('project:list');

    exposed.api.inspectDirectory('/tmp/demo');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:inspectDirectory', '/tmp/demo');

    exposed.api.validateProjectDraft({ name: 'Demo' });
    expect(mockInvoke).toHaveBeenLastCalledWith('project:validateDraft', { name: 'Demo' });

    exposed.api.createProject({ name: 'Demo' });
    expect(mockInvoke).toHaveBeenLastCalledWith('project:create', { name: 'Demo' });

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

    exposed.api.openProject('p1');
    expect(mockInvoke).toHaveBeenLastCalledWith('project:open', 'p1');

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
