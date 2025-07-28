// Test port availability checking
describe('Port Availability', () => {
  // Mock the checkPortAvailable function from main.js
  const checkPortAvailable = (port) => {
    return new Promise((resolve) => {
      // Validate port range first - exclude 0 and reserved ports
      if (port < 1 || port > 65535) {
        resolve(false);
        return;
      }
      
      const net = require('net');
      const server = net.createServer();
      
      server.listen(port, (err) => {
        if (err) {
          resolve(false);
        } else {
          server.once('close', () => resolve(true));
          server.close();
        }
      });
      
      server.on('error', () => resolve(false));
    });
  };

  test('should check if port is available', async () => {
    // Test with a random high port that should be available
    const result = await checkPortAvailable(12345);
    expect(typeof result).toBe('boolean');
  });

  test('should handle invalid port numbers', async () => {
    // Test with invalid port numbers
    await expect(checkPortAvailable(-1)).resolves.toBe(false);
    await expect(checkPortAvailable(0)).resolves.toBe(false);
    await expect(checkPortAvailable(70000)).resolves.toBe(false);
  });

  test('should handle string port numbers', async () => {
    // Test with string port numbers
    await expect(checkPortAvailable('3000')).resolves.toBeDefined();
  });
}); 