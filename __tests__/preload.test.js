// Tests the real preload.js by mocking electron and capturing the API it
// exposes via contextBridge (rather than re-declaring a copy of the object).

// Names must be prefixed with `mock` to satisfy jest.mock factory hoisting.
const mockInvoke = jest.fn(() => Promise.resolve());
const mockOn = jest.fn();
const mockRemoveListener = jest.fn();
let exposed; // { key, api } captured from contextBridge.exposeInMainWorld

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
  test('exposes localwrapAPI with the expected surface', () => {
    expect(exposed.key).toBe('localwrapAPI');
    const api = exposed.api;
    expect(api.isElectron).toBe(true);
    expect(api.platform).toBe('desktop');
    expect(typeof api.version).toBe('string');
    for (const method of [
      'runScript',
      'stopScript',
      'onScriptOutput',
      'onScriptExit',
      'selectDirectory',
      'getCurrentDirectory',
    ]) {
      expect(typeof api[method]).toBe('function');
    }
  });

  test('runScript / stopScript invoke the correct IPC channels', () => {
    mockInvoke.mockClear();
    exposed.api.runScript({ command: 'npm start' });
    expect(mockInvoke).toHaveBeenCalledWith('script:run', { command: 'npm start' });

    mockInvoke.mockClear();
    exposed.api.stopScript(123);
    expect(mockInvoke).toHaveBeenCalledWith('script:stop', 123);
  });

  test('onScriptOutput subscribes and returns an unsubscribe function', () => {
    mockOn.mockClear();
    mockRemoveListener.mockClear();
    const cb = jest.fn();
    const unsubscribe = exposed.api.onScriptOutput(cb);
    expect(mockOn).toHaveBeenCalledWith('script:output', expect.any(Function));

    // The registered listener should forward the event payload to the callback.
    const listener = mockOn.mock.calls[0][1];
    listener({}, { pid: 1, line: 'hello' });
    expect(cb).toHaveBeenCalledWith({ pid: 1, line: 'hello' });

    unsubscribe();
    expect(mockRemoveListener).toHaveBeenCalledWith('script:output', listener);
  });
});
