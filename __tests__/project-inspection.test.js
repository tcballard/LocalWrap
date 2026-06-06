const fs = require('fs');
const os = require('os');
const path = require('path');
const { inspectProjectDirectory } = require('../lib/projectInspection');

function createTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-inspect-'));
}

describe('inspectProjectDirectory', () => {
  let tempDir;

  afterEach(() => {
    if (tempDir) {
      fs.rmSync(tempDir, { recursive: true, force: true });
      tempDir = null;
    }
  });

  test('returns manual-command warnings when package.json is missing', async () => {
    tempDir = createTempDir();

    const profile = await inspectProjectDirectory(tempDir, {
      findAvailablePort: jest.fn(() => Promise.resolve(5173)),
    });

    expect(profile).toMatchObject({
      cwd: tempDir,
      name: path.basename(tempDir),
      recommendedCommand: 'npm run dev',
      suggestedPort: 5173,
      suggestedUrl: 'http://localhost:5173',
    });
    expect(profile.scripts).toEqual([]);
    expect(profile.warnings.map((warning) => warning.code)).toEqual([
      'package-json-missing',
      'scripts-missing',
    ]);
  });

  test('reports invalid package.json and falls back to manual command entry', async () => {
    tempDir = createTempDir();
    fs.writeFileSync(path.join(tempDir, 'package.json'), '{nope');

    const profile = await inspectProjectDirectory(tempDir);

    expect(profile.recommendedCommand).toBe('npm run dev');
    expect(profile.warnings.map((warning) => warning.code)).toEqual([
      'package-json-invalid',
      'scripts-missing',
    ]);
  });

  test('prefers common scripts and package name', async () => {
    tempDir = createTempDir();
    fs.writeFileSync(
      path.join(tempDir, 'package.json'),
      JSON.stringify({
        name: 'demo-app',
        scripts: {
          preview: 'vite preview',
          test: 'jest',
          dev: 'vite',
          start: 'node server.js',
        },
      })
    );

    const profile = await inspectProjectDirectory(tempDir, {
      preferredPort: 3000,
      findAvailablePort: jest.fn(() => Promise.resolve(3001)),
    });

    expect(profile.name).toBe('demo-app');
    expect(profile.recommendedCommand).toBe('npm run dev');
    expect(profile.scripts.map((script) => script.command)).toEqual([
      'npm run dev',
      'npm start',
      'npm run preview',
      'npm run test',
    ]);
    expect(profile.suggestedUrl).toBe('http://localhost:3001');
    expect(profile.warnings).toEqual([]);
  });

  test('uses alphabetical fallback when no preferred scripts exist', async () => {
    tempDir = createTempDir();
    fs.writeFileSync(
      path.join(tempDir, 'package.json'),
      JSON.stringify({
        scripts: {
          zzz: 'node zzz.js',
          aaa: 'node aaa.js',
        },
      })
    );

    const profile = await inspectProjectDirectory(tempDir);

    expect(profile.recommendedCommand).toBe('npm run aaa');
    expect(profile.scripts.map((script) => script.name)).toEqual(['aaa', 'zzz']);
  });
});
