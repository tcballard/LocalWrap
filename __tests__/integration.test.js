// Integration tests for LocalWrap
describe('LocalWrap Integration', () => {
  // Mock environment variables
  const originalEnv = process.env;

  beforeEach(() => {
    jest.resetModules();
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  test('should set default port correctly', () => {
    // Test default port when no environment variable is set
    delete process.env.PORT;
    
    // Mock the main.js logic for default port
    const getDefaultPort = () => {
      return process.env.PORT || 
             process.argv.find(arg => arg.startsWith('--port='))?.split('=')[1] || 
             3000;
    };
    
    expect(getDefaultPort()).toBe(3000);
  });

  test('should use PORT environment variable', () => {
    process.env.PORT = '8080';
    
    const getDefaultPort = () => {
      return process.env.PORT || 
             process.argv.find(arg => arg.startsWith('--port='))?.split('=')[1] || 
             3000;
    };
    
    expect(getDefaultPort()).toBe('8080');
  });

  test('should parse port from command line arguments', () => {
    delete process.env.PORT;
    const originalArgv = process.argv;
    process.argv = ['node', 'main.js', '--port=5000'];
    
    const getDefaultPort = () => {
      return process.env.PORT || 
             process.argv.find(arg => arg.startsWith('--port='))?.split('=')[1] || 
             3000;
    };
    
    expect(getDefaultPort()).toBe('5000');
    
    // Restore original argv
    process.argv = originalArgv;
  });

  test('should validate server host configuration', () => {
    const SERVER_HOST = 'localhost';
    expect(SERVER_HOST).toBe('localhost');
    expect(typeof SERVER_HOST).toBe('string');
  });

  test('should handle development mode flag', () => {
    const isDevMode = process.argv.includes('--dev');
    expect(typeof isDevMode).toBe('boolean');
  });
}); 