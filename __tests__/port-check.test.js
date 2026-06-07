const {
  checkPortAvailable,
  findAvailablePort,
  isValidProjectPort,
  normalizeProjectPort,
  parsePort,
} = require('../lib/portUtils');

describe('port utilities', () => {
  test('parses and validates project ports', () => {
    expect(parsePort('3000')).toBe(3000);
    expect(parsePort(' 5173 ')).toBe(5173);
    expect(Number.isNaN(parsePort('abc'))).toBe(true);
    expect(isValidProjectPort(1000)).toBe(true);
    expect(isValidProjectPort(65535)).toBe(true);
    expect(isValidProjectPort(999)).toBe(false);
    expect(normalizeProjectPort('bad', 5173)).toBe(5173);
  });

  test('reports invalid ports as unavailable', async () => {
    await expect(checkPortAvailable(-1)).resolves.toBe(false);
    await expect(checkPortAvailable(0)).resolves.toBe(false);
    await expect(checkPortAvailable(70000)).resolves.toBe(false);
  });

  test('findAvailablePort skips a busy port', async () => {
    const checker = jest.fn((port) => Promise.resolve(port !== 3000));

    await expect(
      findAvailablePort(3000, { checkPortAvailable: checker, scanLimit: 5 })
    ).resolves.toBe(3001);
    expect(checker).toHaveBeenCalledWith(3000, '127.0.0.1');
    expect(checker).toHaveBeenCalledWith(3001, '127.0.0.1');
  });
});
