const fs = require('fs');
const os = require('os');
const path = require('path');
const { validateProjectDraft } = require('../lib/projectValidation');

function createTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-validate-'));
}

function createDraft(cwd, overrides = {}) {
  return {
    name: 'Demo',
    cwd,
    command: 'npm run dev',
    port: 3000,
    url: 'http://localhost:3000',
    openOnReady: true,
    ...overrides,
  };
}

describe('validateProjectDraft', () => {
  let tempDir;

  beforeEach(() => {
    tempDir = createTempDir();
  });

  afterEach(() => {
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  test('accepts a valid local project draft', async () => {
    const result = await validateProjectDraft(createDraft(tempDir), {
      checkPortAvailable: jest.fn(() => Promise.resolve(true)),
    });

    expect(result.valid).toBe(true);
    expect(result.errors).toEqual([]);
    expect(result.warnings).toEqual([]);
  });

  test('returns field errors for missing directory, unsafe command, invalid port, and invalid URL', async () => {
    const result = await validateProjectDraft(
      createDraft(path.join(tempDir, 'missing'), {
        command: 'bash run.sh',
        port: 999,
        url: 'https://example.com:3000',
      })
    );

    expect(result.valid).toBe(false);
    expect(result.errors.map((error) => error.field)).toEqual(['cwd', 'command', 'port', 'url']);
  });

  test('warns for busy ports without blocking save', async () => {
    const result = await validateProjectDraft(createDraft(tempDir), {
      checkPortAvailable: jest.fn(() => Promise.resolve(false)),
    });

    expect(result.valid).toBe(true);
    expect(result.warnings).toEqual([
      {
        field: 'port',
        code: 'port-busy',
        message: 'Port appears to be in use.',
      },
    ]);
  });

  test('warns when URL port does not match project port', async () => {
    const result = await validateProjectDraft(
      createDraft(tempDir, { url: 'http://localhost:5173' })
    );

    expect(result.valid).toBe(true);
    expect(result.warnings).toEqual([
      {
        field: 'url',
        code: 'url-port-mismatch',
        message: 'URL port does not match the project port.',
      },
    ]);
  });
});
