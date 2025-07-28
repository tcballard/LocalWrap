// Test URL validation functionality
describe('URL Validation', () => {
  // Mock the validateLocalhostURL function from main.js
  const validateLocalhostURL = (targetURL) => {
    try {
      const parsedURL = new URL(targetURL);
      const port = parseInt(parsedURL.port);
      return (
        (parsedURL.hostname === 'localhost' || parsedURL.hostname === '127.0.0.1') &&
        port >= 1000 && port <= 65535 && // Valid port range
        parsedURL.protocol === 'http:'
      );
    } catch (error) {
      console.error('Invalid URL:', error);
      return false;
    }
  };

  test('should validate correct localhost URLs', () => {
    expect(validateLocalhostURL('http://localhost:3000')).toBe(true);
    expect(validateLocalhostURL('http://127.0.0.1:8080')).toBe(true);
    expect(validateLocalhostURL('http://localhost:5000')).toBe(true);
  });

  test('should reject invalid URLs', () => {
    expect(validateLocalhostURL('https://localhost:3000')).toBe(false); // wrong protocol
    expect(validateLocalhostURL('http://google.com:3000')).toBe(false); // wrong hostname
    expect(validateLocalhostURL('http://localhost:999')).toBe(false); // port too low
    expect(validateLocalhostURL('http://localhost:70000')).toBe(false); // port too high
    expect(validateLocalhostURL('not-a-url')).toBe(false); // invalid URL
    expect(validateLocalhostURL('')).toBe(false); // empty string
  });

  test('should handle edge cases', () => {
    expect(validateLocalhostURL('http://localhost:1000')).toBe(true); // minimum port
    expect(validateLocalhostURL('http://localhost:65535')).toBe(true); // maximum port
    expect(validateLocalhostURL('http://localhost:999')).toBe(false); // below minimum
    expect(validateLocalhostURL('http://localhost:65536')).toBe(false); // above maximum
  });
}); 