const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  ACTIONS,
  buildDoctorReport,
  diagnoseProjectDraft,
  getDoctorActionPatch,
  updateRuntimeDiagnosis,
} = require('../lib/projectDoctor');

function createTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-doctor-'));
}

function createDraft(cwd, overrides = {}) {
  return {
    id: 'project-1',
    name: 'Demo',
    cwd,
    command: 'npm run dev',
    port: 3000,
    url: 'http://localhost:3000',
    openOnReady: true,
    ...overrides,
  };
}

function findCheck(diagnosis, id) {
  return diagnosis.checks.find((check) => check.id === id);
}

describe('Project Doctor', () => {
  let tempDir;

  beforeEach(() => {
    tempDir = createTempDir();
    fs.writeFileSync(
      path.join(tempDir, 'package.json'),
      JSON.stringify({
        scripts: { dev: 'vite' },
      })
    );
  });

  afterEach(() => {
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  test('returns healthy checks for a valid project', async () => {
    const diagnosis = await diagnoseProjectDraft(createDraft(tempDir), {
      checkPortAvailable: jest.fn(() => Promise.resolve(true)),
    });

    expect(diagnosis.status).toBe('idle');
    expect(diagnosis.summary).toMatch(/ready to start/);
    expect(findCheck(diagnosis, 'directory').status).toBe('pass');
    expect(findCheck(diagnosis, 'command').status).toBe('pass');
    expect(findCheck(diagnosis, 'port').status).toBe('pass');
    expect(findCheck(diagnosis, 'url').status).toBe('pass');
  });

  test('reports missing directory as a blocking failure', async () => {
    const diagnosis = await diagnoseProjectDraft(createDraft(path.join(tempDir, 'missing')));

    expect(diagnosis.status).toBe('failed');
    expect(findCheck(diagnosis, 'directory')).toMatchObject({
      status: 'fail',
      message: 'Directory does not exist.',
    });
  });

  test('reports unsafe commands as a blocking failure', async () => {
    const diagnosis = await diagnoseProjectDraft(createDraft(tempDir, { command: 'bash run.sh' }));

    expect(diagnosis.status).toBe('failed');
    expect(findCheck(diagnosis, 'command').status).toBe('fail');
    expect(findCheck(diagnosis, 'command').message).toMatch(/not allowed/);
  });

  test('warns for a busy port and offers the free-port action', async () => {
    const diagnosis = await diagnoseProjectDraft(createDraft(tempDir), {
      checkPortAvailable: jest.fn(() => Promise.resolve(false)),
    });

    const portCheck = findCheck(diagnosis, 'port');
    expect(diagnosis.status).toBe('attention');
    expect(portCheck.status).toBe('warn');
    expect(portCheck.actions).toContainEqual(
      expect.objectContaining({ id: ACTIONS.USE_FREE_PORT })
    );
  });

  test('warns for URL port mismatch and offers the sync action', async () => {
    const diagnosis = await diagnoseProjectDraft(
      createDraft(tempDir, { url: 'http://localhost:5173' })
    );

    const urlCheck = findCheck(diagnosis, 'url');
    expect(diagnosis.status).toBe('attention');
    expect(urlCheck.status).toBe('warn');
    expect(urlCheck.actions).toContainEqual(
      expect.objectContaining({ id: ACTIONS.SYNC_URL_TO_PORT })
    );
  });

  test('warns about missing node_modules with inferred install hint', async () => {
    fs.writeFileSync(
      path.join(tempDir, 'package.json'),
      JSON.stringify({
        scripts: { dev: 'vite' },
        devDependencies: { vite: '^6.0.0' },
      })
    );
    fs.writeFileSync(path.join(tempDir, 'pnpm-lock.yaml'), '');

    const diagnosis = await diagnoseProjectDraft(createDraft(tempDir));
    expect(findCheck(diagnosis, 'dependencies')).toMatchObject({
      status: 'warn',
      message: expect.stringContaining('pnpm install'),
    });
  });

  test('builds safe action patches and rejects unknown actions', () => {
    expect(
      getDoctorActionPatch(createDraft(tempDir), ACTIONS.USE_FREE_PORT, { port: 5173 })
    ).toEqual({
      port: 5173,
      url: 'http://localhost:5173',
    });

    expect(getDoctorActionPatch(createDraft(tempDir), ACTIONS.SYNC_URL_TO_PORT)).toEqual({
      url: 'http://localhost:3000',
    });

    expect(() => getDoctorActionPatch(createDraft(tempDir), 'install-deps')).toThrow(/Unknown/);
  });

  test('maps runtime updates into diagnosis checks and timeline', () => {
    const diagnosis = updateRuntimeDiagnosis(undefined, {
      status: 'waiting',
      summary: 'Waiting for app response.',
      check: {
        id: 'readiness',
        status: 'running',
        message: 'Waiting for http://localhost:3000.',
      },
      timeline: {
        status: 'info',
        message: 'Waiting for URL.',
      },
    });

    expect(diagnosis.status).toBe('waiting');
    expect(findCheck(diagnosis, 'readiness').status).toBe('running');
    expect(diagnosis.timeline.at(-1).message).toBe('Waiting for URL.');
  });

  test('builds a concise diagnostic report', async () => {
    const diagnosis = await diagnoseProjectDraft(createDraft(tempDir));
    const report = buildDoctorReport(createDraft(tempDir), {
      status: 'running-unresponsive',
      readinessMessage: 'No response.',
      lastExitCode: 1,
      diagnosis,
      logs: ['one', 'two'],
    });

    expect(report).toContain('LocalWrap Doctor Report');
    expect(report).toContain('Project: Demo');
    expect(report).toContain('Doctor Status:');
    expect(report).toContain('Recent Logs:');
    expect(report).toContain('two');
  });
});
