// Jest setup file
process.env.NODE_ENV = 'test';

// Mock Electron for testing
jest.mock('electron', () => ({
  app: {
    on: jest.fn(),
    whenReady: jest.fn().mockResolvedValue(),
    quit: jest.fn(),
    isReady: jest.fn().mockReturnValue(true)
  },
  BrowserWindow: jest.fn().mockImplementation(() => ({
    loadURL: jest.fn(),
    on: jest.fn(),
    webContents: {
      on: jest.fn()
    },
    show: jest.fn(),
    hide: jest.fn(),
    close: jest.fn(),
    isDestroyed: jest.fn().mockReturnValue(false)
  })),
  ipcMain: {
    handle: jest.fn(),
    on: jest.fn()
  }
})); 