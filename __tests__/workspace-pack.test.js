const fs = require('fs');
const os = require('os');
const path = require('path');
const {
  buildWorkspacePack,
  normalizeWorkspacePack,
  readWorkspacePack,
  writeWorkspacePack,
} = require('../lib/workspacePack');

function createFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-pack-'));
  fs.mkdirSync(path.join(root, 'apps', 'web'), { recursive: true });
  fs.mkdirSync(path.join(root, 'services', 'api'), { recursive: true });
  return root;
}

describe('workspace pack', () => {
  let root;

  beforeEach(() => {
    root = createFixture();
  });

  afterEach(() => {
    fs.rmSync(root, { recursive: true, force: true });
  });

  test('normalizes a v1 pack into local project drafts and workspace profiles', () => {
    const pack = normalizeWorkspacePack(
      {
        localwrap: 1,
        name: 'Acme stack',
        projects: [
          {
            id: 'web',
            name: 'Web',
            path: 'apps/web',
            command: 'npm run dev',
            port: '5173',
          },
          {
            id: 'api',
            name: 'API',
            path: 'services/api',
            command: 'node server.js',
            port: 4000,
            url: 'http://localhost:4000',
            openOnReady: false,
          },
        ],
        workspaces: [{ id: 'full-stack', name: 'Full stack', projects: ['api', 'web'] }],
      },
      { rootDir: root, packPath: path.join(root, '.localwrap', 'workspace.json') }
    );

    expect(pack.projects).toEqual([
      expect.objectContaining({
        id: 'web',
        cwd: path.join(root, 'apps', 'web'),
        command: 'npm run dev',
        port: 5173,
        url: 'http://localhost:5173',
        openOnReady: true,
      }),
      expect.objectContaining({
        id: 'api',
        cwd: path.join(root, 'services', 'api'),
        openOnReady: false,
      }),
    ]);
    expect(pack.workspaces).toEqual([
      { id: 'full-stack', name: 'Full stack', projects: ['api', 'web'] },
    ]);
  });

  test('rejects project paths that escape the workspace folder', () => {
    expect(() =>
      normalizeWorkspacePack(
        {
          localwrap: 1,
          projects: [{ id: 'bad', path: '../elsewhere', command: 'npm start' }],
        },
        { rootDir: root }
      )
    ).toThrow(/escapes/);
  });

  test('workspace profiles can reference human-written project ids before normalization', () => {
    fs.mkdirSync(path.join(root, 'apps', 'admin'), { recursive: true });

    const pack = normalizeWorkspacePack(
      {
        localwrap: 1,
        projects: [
          { id: 'Web App', path: 'apps/web', command: 'npm run dev' },
          { id: 'Admin App', path: 'apps/admin', command: 'npm start' },
        ],
        workspaces: [{ name: 'Frontend', projects: ['Web App', 'Admin App'] }],
      },
      { rootDir: root }
    );

    expect(pack.projects.map((project) => project.id)).toEqual(['web-app', 'admin-app']);
    expect(pack.workspaces).toEqual([
      { id: 'frontend', name: 'Frontend', projects: ['web-app', 'admin-app'] },
    ]);
  });

  test('reads and writes the canonical .localwrap workspace file', () => {
    const pack = {
      localwrap: 1,
      name: 'Acme stack',
      projects: [{ id: 'web', name: 'Web', path: 'apps/web', command: 'npm run dev' }],
      workspaces: [{ id: 'default', name: 'Default', projects: ['web'] }],
    };

    const packPath = writeWorkspacePack(root, pack);
    const normalized = readWorkspacePack(root);

    expect(packPath).toBe(path.join(root, '.localwrap', 'workspace.json'));
    expect(normalized.name).toBe('Acme stack');
    expect(normalized.packPath).toBe(packPath);
    expect(normalized.projects[0].cwd).toBe(path.join(root, 'apps', 'web'));
  });

  test('builds a portable pack from saved projects under the selected folder', () => {
    const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-outside-'));
    const { pack, skippedProjects } = buildWorkspacePack({
      rootDir: root,
      projects: [
        {
          id: 'p1',
          name: 'Web',
          cwd: path.join(root, 'apps', 'web'),
          command: 'npm run dev',
          port: 5173,
          url: 'http://localhost:5173',
          openOnReady: true,
        },
        {
          id: 'p2',
          name: 'Elsewhere',
          cwd: outside,
          command: 'npm start',
          port: 3000,
          url: 'http://localhost:3000',
        },
      ],
      workspace: {
        savedWorkspaces: [{ id: 'w1', name: 'Frontend', projectIds: ['p1', 'p2'] }],
      },
      name: 'Exported stack',
    });

    fs.rmSync(outside, { recursive: true, force: true });

    expect(pack).toMatchObject({
      localwrap: 1,
      name: 'Exported stack',
      projects: [{ id: 'web', path: path.join('apps', 'web'), command: 'npm run dev' }],
      workspaces: [{ id: 'frontend', name: 'Frontend', projects: ['web'] }],
    });
    expect(skippedProjects).toEqual([
      { id: 'p2', name: 'Elsewhere', reason: 'outside-workspace-folder' },
    ]);
  });
});
