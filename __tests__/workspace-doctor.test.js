const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  diagnoseWorkspace,
  getEnvWarning,
  getProjectIdsForWorkspace,
  parseEnvKeys,
} = require('../lib/workspaceDoctor');

function createTempDir() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-workspace-doctor-'));
}

function createProject(cwd, overrides = {}) {
  return {
    id: overrides.id || path.basename(cwd),
    name: overrides.name || path.basename(cwd),
    cwd,
    command: 'npm run dev',
    port: overrides.port || 3000,
    url: `http://localhost:${overrides.port || 3000}`,
    ...overrides,
  };
}

function findCheck(diagnosis, id) {
  return diagnosis.checks.find((check) => check.id === id);
}

describe('Workspace Doctor', () => {
  let root;
  let webDir;
  let apiDir;

  beforeEach(() => {
    root = createTempDir();
    webDir = path.join(root, 'web');
    apiDir = path.join(root, 'api');
    fs.mkdirSync(webDir);
    fs.mkdirSync(apiDir);
    fs.writeFileSync(
      path.join(webDir, 'package.json'),
      JSON.stringify({ scripts: { dev: 'vite' } })
    );
    fs.writeFileSync(
      path.join(apiDir, 'package.json'),
      JSON.stringify({ scripts: { dev: 'node server.js' } })
    );
  });

  afterEach(() => {
    fs.rmSync(root, { recursive: true, force: true });
  });

  test('reports a ready workspace when every project passes preflight', async () => {
    const diagnosis = await diagnoseWorkspace({
      projects: [
        createProject(webDir, { id: 'web', port: 5173 }),
        createProject(apiDir, { id: 'api', port: 4000 }),
      ],
      workspace: {},
    });

    expect(diagnosis.status).toBe('ready');
    expect(diagnosis.totals).toMatchObject({ projects: 2, ready: 2, warnings: 0, blockers: 0 });
    expect(diagnosis.startableProjectIds).toEqual(['web', 'api']);
    expect(findCheck(diagnosis, 'ports').status).toBe('pass');
  });

  test('blocks projects with missing folders and unsafe commands', async () => {
    const diagnosis = await diagnoseWorkspace({
      projects: [
        createProject(path.join(root, 'missing'), { id: 'missing' }),
        createProject(webDir, { id: 'unsafe', command: 'bash run.sh' }),
      ],
      workspace: {},
    });

    expect(diagnosis.status).toBe('blocked');
    expect(diagnosis.blockedProjectIds).toEqual(['missing', 'unsafe']);
    expect(findCheck(diagnosis, 'directories').status).toBe('fail');
    expect(findCheck(diagnosis, 'commands').status).toBe('fail');
  });

  test('warns about missing dependencies and env values without blocking startup', async () => {
    fs.writeFileSync(
      path.join(webDir, 'package.json'),
      JSON.stringify({ scripts: { dev: 'vite' }, devDependencies: { vite: '^6.0.0' } })
    );
    fs.writeFileSync(path.join(apiDir, '.env.example'), 'DATABASE_URL=\nAPI_TOKEN=\n');
    fs.writeFileSync(path.join(apiDir, '.env'), 'DATABASE_URL=postgres://localhost\n');

    const diagnosis = await diagnoseWorkspace({
      projects: [
        createProject(webDir, { id: 'web', port: 5173 }),
        createProject(apiDir, { id: 'api', port: 4000 }),
      ],
      workspace: {},
    });

    expect(diagnosis.status).toBe('attention');
    expect(diagnosis.startableProjectIds).toEqual(['web', 'api']);
    expect(findCheck(diagnosis, 'dependencies').status).toBe('warn');
    expect(findCheck(diagnosis, 'env').status).toBe('warn');
    expect(diagnosis.projects.find((project) => project.id === 'api').summary).toContain(
      'API_TOKEN'
    );
  });

  test('marks duplicate workspace ports as blockers', async () => {
    const diagnosis = await diagnoseWorkspace({
      projects: [
        createProject(webDir, { id: 'web', port: 3000 }),
        createProject(apiDir, { id: 'api', port: 3000 }),
      ],
      workspace: {},
    });

    expect(diagnosis.status).toBe('blocked');
    expect(findCheck(diagnosis, 'ports')).toMatchObject({
      status: 'fail',
      message: '2 blocker(s) found.',
    });
    expect(diagnosis.startableProjectIds).toEqual([]);
  });

  test('honors selected workspace profiles before falling back to all projects', () => {
    const target = getProjectIdsForWorkspace(
      [createProject(webDir, { id: 'web' }), createProject(apiDir, { id: 'api' })],
      { savedWorkspaces: [{ id: 'frontend', name: 'Frontend', projectIds: ['web'] }] },
      'frontend'
    );

    expect(target).toEqual({
      kind: 'profile',
      profileId: 'frontend',
      name: 'Frontend',
      projectIds: ['web'],
    });
  });

  test('parses env examples and reports missing env files', () => {
    fs.writeFileSync(
      path.join(webDir, '.env.example'),
      '# comment\nexport API_URL=\nVITE_TOKEN=\n'
    );

    expect(Array.from(parseEnvKeys('FOO=1\nexport BAR=\n# NOPE=\n'))).toEqual(['FOO', 'BAR']);
    expect(getEnvWarning(webDir)).toMatchObject({
      code: 'env-file-missing',
      missingKeys: ['API_URL', 'VITE_TOKEN'],
    });
  });
});
