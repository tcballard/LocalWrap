// Test server management functionality
describe('Server Management', () => {
  // Mock server management functions
  const servers = new Map();

  const getServersStatus = () => {
    const status = {};
    for (const [port, server] of servers.entries()) {
      status[port] = {
        running: server && !server.destroyed,
        port: port,
        uptime: server ? Date.now() - server.startTime : 0
      };
    }
    return status;
  };

  const getServerStatus = (port) => {
    const server = servers.get(port);
    if (!server) {
      return { running: false, port, error: 'Server not found' };
    }
    return {
      running: !server.destroyed,
      port: port,
      uptime: Date.now() - server.startTime
    };
  };

  beforeEach(() => {
    servers.clear();
  });

  test('should return empty status when no servers are running', () => {
    const status = getServersStatus();
    expect(status).toEqual({});
  });

  test('should return server status for running servers', () => {
    // Mock a running server
    const mockServer = {
      destroyed: false,
      startTime: Date.now() - 5000 // 5 seconds ago
    };
    servers.set(3000, mockServer);

    const status = getServersStatus();
    expect(status[3000]).toBeDefined();
    expect(status[3000].running).toBe(true);
    expect(status[3000].port).toBe(3000);
    expect(status[3000].uptime).toBeGreaterThan(0);
  });

  test('should return correct status for specific server', () => {
    const mockServer = {
      destroyed: false,
      startTime: Date.now() - 3000
    };
    servers.set(8080, mockServer);

    const status = getServerStatus(8080);
    expect(status.running).toBe(true);
    expect(status.port).toBe(8080);
    expect(status.uptime).toBeGreaterThan(0);
  });

  test('should return error for non-existent server', () => {
    const status = getServerStatus(9999);
    expect(status.running).toBe(false);
    expect(status.port).toBe(9999);
    expect(status.error).toBe('Server not found');
  });

  test('should handle stopped servers', () => {
    const mockServer = {
      destroyed: true,
      startTime: Date.now() - 1000
    };
    servers.set(4000, mockServer);

    const status = getServerStatus(4000);
    expect(status.running).toBe(false);
  });
}); 