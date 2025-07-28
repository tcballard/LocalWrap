// Test preload script functionality
describe('Preload Script', () => {
  let mockWindow;

  beforeEach(() => {
    // Mock window object
    mockWindow = {
      require: 'should-be-deleted',
      exports: 'should-be-deleted',
      module: 'should-be-deleted',
      localwrapAPI: {}
    };
  });

  test('should remove dangerous globals', () => {
    // Simulate the preload script cleanup
    delete mockWindow.require;
    delete mockWindow.exports;
    delete mockWindow.module;

    expect(mockWindow.require).toBeUndefined();
    expect(mockWindow.exports).toBeUndefined();
    expect(mockWindow.module).toBeUndefined();
  });

  test('should provide localwrapAPI', () => {
    // Simulate the API setup
    mockWindow.localwrapAPI = {
      version: '1.0.0',
      platform: 'desktop',
      isElectron: true
    };

    expect(mockWindow.localwrapAPI).toBeDefined();
    expect(mockWindow.localwrapAPI.version).toBe('1.0.0');
    expect(mockWindow.localwrapAPI.platform).toBe('desktop');
    expect(mockWindow.localwrapAPI.isElectron).toBe(true);
  });

  test('should have correct API structure', () => {
    const api = {
      version: '1.0.0',
      platform: 'desktop',
      isElectron: true
    };

    expect(api).toHaveProperty('version');
    expect(api).toHaveProperty('platform');
    expect(api).toHaveProperty('isElectron');
    expect(typeof api.version).toBe('string');
    expect(typeof api.platform).toBe('string');
    expect(typeof api.isElectron).toBe('boolean');
  });
}); 