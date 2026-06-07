const fs = require('fs');
const os = require('os');
const path = require('path');
const { discoverPackageScripts } = require('../lib/packageScripts');
const { probeURL, waitForReady } = require('../lib/readiness');

function createTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-integration-'));
}

describe('project launcher integration helpers', () => {
  let tempDir;

  afterEach(() => {
    if (tempDir) {
      fs.rmSync(tempDir, { recursive: true, force: true });
      tempDir = null;
    }
  });

  test('discovers package scripts in preferred launch order', () => {
    tempDir = createTempDir();
    fs.writeFileSync(
      path.join(tempDir, 'package.json'),
      JSON.stringify({
        scripts: {
          test: 'jest',
          preview: 'vite preview',
          dev: 'vite',
          start: 'node server.js',
        },
      })
    );

    expect(discoverPackageScripts(tempDir).map((script) => script.command)).toEqual([
      'npm run dev',
      'npm start',
      'npm run preview',
      'npm run test',
    ]);
  });

  test('waitForReady polls until a probe succeeds', async () => {
    const probe = jest.fn().mockResolvedValueOnce(false).mockResolvedValueOnce(true);

    await expect(
      waitForReady('http://localhost:3000', {
        timeoutMs: 200,
        intervalMs: 1,
        probe,
      })
    ).resolves.toBe(true);
    expect(probe).toHaveBeenCalledTimes(2);
  });

  test('probeURL rejects non-local URLs without network access', async () => {
    await expect(probeURL('https://example.com:3000')).resolves.toBe(false);
  });
});
