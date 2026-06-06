const { validateLocalhostURL, validateLocalProjectURL } = require('../lib/urlValidation');

describe('local URL validation', () => {
  test('accepts local http project URLs on allowed ports', () => {
    expect(validateLocalProjectURL('http://localhost:3000')).toBe(true);
    expect(validateLocalProjectURL('http://127.0.0.1:8080')).toBe(true);
    expect(validateLocalProjectURL('http://[::1]:5173')).toBe(true);
  });

  test('accepts https for project URLs but keeps legacy localhost validation http-only', () => {
    expect(validateLocalProjectURL('https://localhost:3000')).toBe(true);
    expect(validateLocalhostURL('https://localhost:3000')).toBe(false);
  });

  test('rejects non-local hosts, invalid ports, and malformed input', () => {
    expect(validateLocalProjectURL('http://example.com:3000')).toBe(false);
    expect(validateLocalProjectURL('http://localhost:999')).toBe(false);
    expect(validateLocalProjectURL('http://localhost:65536')).toBe(false);
    expect(validateLocalProjectURL('ftp://localhost:3000')).toBe(false);
    expect(validateLocalProjectURL('not-a-url')).toBe(false);
    expect(validateLocalProjectURL('')).toBe(false);
  });
});
