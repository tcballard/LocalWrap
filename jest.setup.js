// Jest setup file
process.env.NODE_ENV = 'test';

// Suppress expected console.error messages in tests
const originalConsoleError = console.error;
console.error = (...args) => {
  // Suppress expected URL validation errors in tests
  if (args[0] === 'Invalid URL:' && args[1]?.code === 'ERR_INVALID_URL') {
    return;
  }
  originalConsoleError(...args);
};

// Mock Electron for testing
jest.mock('electron', () => ({
  app: {
    on: jest.fn(),
    whenReady: jest.fn().mockResolvedValue(),
    quit: jest.fn(),
    isReady: jest.fn().mockReturnValue(true),
    getVersion: jest.fn().mockReturnValue('1.0.0'),
    requestSingleInstanceLock: jest.fn().mockReturnValue(true)
  },
  BrowserWindow: jest.fn().mockImplementation(() => ({
    loadURL: jest.fn(),
    on: jest.fn(),
    webContents: {
      on: jest.fn(),
      setWindowOpenHandler: jest.fn()
    },
    show: jest.fn(),
    hide: jest.fn(),
    close: jest.fn(),
    isDestroyed: jest.fn().mockReturnValue(false),
    setTitle: jest.fn(),
    once: jest.fn()
  })),
  Menu: {
    buildFromTemplate: jest.fn().mockReturnValue({})
  },
  Tray: jest.fn().mockImplementation(() => ({
    setContextMenu: jest.fn(),
    setToolTip: jest.fn(),
    on: jest.fn()
  })),
  shell: {
    openExternal: jest.fn()
  },
  dialog: {
    showMessageBox: jest.fn(),
    showErrorBox: jest.fn()
  },
  nativeImage: {
    createFromPath: jest.fn().mockReturnValue({}),
    createEmpty: jest.fn().mockReturnValue({})
  }
})); 