const fs = require('fs');
const os = require('os');
const path = require('path');
const { ProjectStore, isStoreCorruptError } = require('../lib/projectStore');

function createFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-store-'));
  const cwd = path.join(root, 'demo-app');
  fs.mkdirSync(cwd);
  return {
    root,
    cwd,
    filePath: path.join(root, 'projects.json'),
  };
}

describe('ProjectStore', () => {
  let fixture;
  let tick;

  beforeEach(() => {
    fixture = createFixture();
    tick = 0;
  });

  afterEach(() => {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  });

  function createStore() {
    return new ProjectStore({
      filePath: fixture.filePath,
      idFactory: () => 'project-1',
      now: () => `2026-06-05T00:00:0${tick++}.000Z`,
    });
  }

  test('creates and persists a normalized project', () => {
    const store = createStore();
    const project = store.create({
      cwd: fixture.cwd,
      command: 'npm run dev',
      port: '5173',
      url: 'http://localhost:5173',
      openOnReady: true,
    });

    expect(project).toMatchObject({
      id: 'project-1',
      name: 'demo-app',
      port: 5173,
      autostart: false,
      openOnReady: true,
    });
    expect(createStore().list()).toHaveLength(1);
  });

  test('updates an existing project and preserves createdAt', () => {
    const store = createStore();
    const project = store.create({
      cwd: fixture.cwd,
      command: 'npm start',
      port: 3000,
      url: 'http://localhost:3000',
    });

    const updated = store.update(project.id, {
      name: 'Renamed',
      command: 'npm run dev',
    });

    expect(updated.name).toBe('Renamed');
    expect(updated.command).toBe('npm run dev');
    expect(updated.createdAt).toBe(project.createdAt);
    expect(updated.updatedAt).not.toBe(project.updatedAt);
  });

  test('preserves optional sample project metadata', () => {
    const store = createStore();
    const project = store.create({
      cwd: fixture.cwd,
      command: 'npm run dev',
      port: 3000,
      url: 'http://localhost:3000',
      isSample: true,
    });

    const updated = store.update(project.id, {
      name: 'Demo Sample',
    });

    expect(project.isSample).toBe(true);
    expect(updated.isSample).toBe(true);
    expect(createStore().list()[0].isSample).toBe(true);
  });

  test('stores last running project ids in workspace metadata', () => {
    const store = createStore();
    const project = store.create({
      cwd: fixture.cwd,
      command: 'npm run dev',
      port: 3000,
      url: 'http://localhost:3000',
    });

    const workspace = store.setLastRunningProjectIds([project.id, 'missing', project.id]);

    expect(workspace).toMatchObject({
      lastRunningProjectIds: [project.id],
      updatedAt: '2026-06-05T00:00:02.000Z',
    });
    expect(createStore().getWorkspace().lastRunningProjectIds).toEqual([project.id]);
    expect(createStore().getWorkspace().savedWorkspaces).toEqual([]);
  });

  test('saves named workspace profiles with valid project ids only', () => {
    const store = createStore();
    const project = store.create({
      cwd: fixture.cwd,
      command: 'npm run dev',
      port: 3000,
      url: 'http://localhost:3000',
    });

    const profile = store.saveWorkspaceProfile({
      name: 'Morning stack',
      projectIds: [project.id, 'missing', project.id],
    });

    expect(profile).toMatchObject({
      id: 'project-1',
      name: 'Morning stack',
      projectIds: [project.id],
      createdAt: '2026-06-05T00:00:02.000Z',
      updatedAt: '2026-06-05T00:00:02.000Z',
      lastStartedAt: null,
    });
    expect(createStore().getWorkspace().savedWorkspaces).toHaveLength(1);
  });

  test('drops deleted projects from workspace profiles', () => {
    const store = createStore();
    const project = store.create({
      cwd: fixture.cwd,
      command: 'npm run dev',
      port: 3000,
      url: 'http://localhost:3000',
    });
    store.saveWorkspaceProfile({
      name: 'Single project',
      projectIds: [project.id],
    });

    store.delete(project.id);

    expect(store.getWorkspace()).toMatchObject({
      lastRunningProjectIds: [],
      savedWorkspaces: [],
    });
  });

  test('reads v3 workspace metadata without saved profiles', () => {
    fs.writeFileSync(
      fixture.filePath,
      JSON.stringify({
        projects: [],
        workspace: {
          lastRunningProjectIds: ['missing'],
          updatedAt: '2026-06-05T00:00:00.000Z',
        },
      })
    );

    expect(createStore().getWorkspace()).toEqual({
      lastRunningProjectIds: [],
      savedWorkspaces: [],
      updatedAt: '2026-06-05T00:00:00.000Z',
    });
  });

  test('imports a workspace pack without duplicating projects or profiles', () => {
    let nextId = 1;
    const store = new ProjectStore({
      filePath: fixture.filePath,
      idFactory: () => `imported-${nextId++}`,
      now: () => `2026-06-05T00:00:0${tick++}.000Z`,
    });
    const pack = {
      packPath: path.join(fixture.root, '.localwrap', 'workspace.json'),
      rootDir: fixture.root,
      projects: [
        {
          id: 'web',
          name: 'Web',
          cwd: fixture.cwd,
          command: 'npm run dev',
          port: 5173,
          url: 'http://localhost:5173',
          autostart: false,
          openOnReady: true,
        },
      ],
      workspaces: [{ id: 'default', name: 'Demo stack', projects: ['web'] }],
    };

    const first = store.importWorkspacePack(pack);
    const second = store.importWorkspacePack({
      ...pack,
      projects: [
        { ...pack.projects[0], name: 'Web App', port: 5174, url: 'http://localhost:5174' },
      ],
    });

    expect(first.importedProjectIds).toEqual(['imported-1']);
    expect(first.importedWorkspaceIds).toEqual(['imported-2']);
    expect(second.importedProjectIds).toEqual([]);
    expect(second.updatedProjectIds).toEqual(['imported-1']);
    expect(second.updatedWorkspaceIds).toEqual(['imported-2']);
    expect(store.list()).toEqual([
      expect.objectContaining({
        id: 'imported-1',
        name: 'Web App',
        port: 5174,
        source: {
          type: 'workspace-pack',
          packPath: pack.packPath,
          packProjectId: 'web',
        },
      }),
    ]);
    expect(store.getWorkspace().savedWorkspaces).toEqual([
      expect.objectContaining({
        id: 'imported-2',
        name: 'Demo stack',
        projectIds: ['imported-1'],
        source: {
          type: 'workspace-pack',
          packPath: pack.packPath,
          packWorkspaceId: 'default',
        },
      }),
    ]);
  });

  test('preserves corrupt project data when starting fresh', () => {
    fs.writeFileSync(fixture.filePath, '{not-json');
    const store = createStore();

    expect(() => store.list()).toThrow(/not valid JSON/);

    const result = store.startFresh();

    const backups = fs
      .readdirSync(fixture.root)
      .filter((file) => file.startsWith('projects.json.corrupt-'));
    expect(backups).toHaveLength(1);
    expect(path.basename(result.preservedPath)).toBe(backups[0]);
    expect(fs.readFileSync(path.join(fixture.root, backups[0]), 'utf8')).toBe('{not-json');
    expect(store.list()).toEqual([]);
  });

  test('rejects unsafe commands, missing directories, and non-local URLs', () => {
    const store = createStore();
    expect(() =>
      store.create({
        cwd: fixture.cwd,
        command: 'bash run.sh',
        port: 3000,
        url: 'http://localhost:3000',
      })
    ).toThrow(/not allowed/);

    expect(() =>
      store.create({
        cwd: path.join(fixture.root, 'missing'),
        command: 'npm start',
        port: 3000,
        url: 'http://localhost:3000',
      })
    ).toThrow(/does not exist/);

    expect(() =>
      store.create({
        cwd: fixture.cwd,
        command: 'npm start',
        port: 3000,
        url: 'https://example.com:3000',
      })
    ).toThrow(/local/);
  });
});

// Durability contract: an unreadable projects.json fails closed (typed
// STORE_CORRUPT error) instead of being treated as empty, writes are atomic,
// and every successful save mirrors the file to a .bak for recovery.
describe('ProjectStore durability', () => {
  let fixture;
  let nextId;

  beforeEach(() => {
    fixture = createFixture();
    nextId = 1;
  });

  afterEach(() => {
    fs.rmSync(fixture.root, { recursive: true, force: true });
  });

  function createStore(options = {}) {
    return new ProjectStore({
      filePath: fixture.filePath,
      idFactory: () => `project-${nextId++}`,
      now: () => '2026-06-10T00:00:00.000Z',
      ...options,
    });
  }

  function createProjectInput(name) {
    return {
      name,
      cwd: fixture.cwd,
      command: 'npm start',
      port: 3000,
      url: 'http://localhost:3000',
    };
  }

  function expectStoreCorrupt(callback) {
    let caught;
    try {
      callback();
    } catch (error) {
      caught = error;
    }
    expect(caught).toBeDefined();
    expect(isStoreCorruptError(caught)).toBe(true);
  }

  test('a missing file still reads as an empty store', () => {
    expect(createStore().list()).toEqual([]);
  });

  test('fails closed on a corrupt projects.json', () => {
    fs.writeFileSync(fixture.filePath, '{ this is not json');

    expectStoreCorrupt(() => createStore().list());
  });

  test('fails closed on an unexpected document shape', () => {
    fs.writeFileSync(fixture.filePath, JSON.stringify({ projects: { nope: true } }));

    expectStoreCorrupt(() => createStore().list());
  });

  test('fails closed on a read error', () => {
    createStore().create(createProjectInput('Survivor'));

    const readError = Object.assign(new Error('EBUSY: resource busy or locked'), {
      code: 'EBUSY',
    });
    const store = createStore({
      fsImpl: {
        ...fs,
        readFileSync: () => {
          throw readError;
        },
      },
    });

    expectStoreCorrupt(() => store.list());
  });

  test('refuses to save over an unreadable store instead of wiping it', () => {
    const store = createStore();
    store.create(createProjectInput('First'));
    store.create(createProjectInput('Second'));
    expect(store.list()).toHaveLength(2);

    // Simulate a crash mid-write / disk corruption.
    const corruptContent = '{ this is not json';
    fs.writeFileSync(fixture.filePath, corruptContent);

    expectStoreCorrupt(() => store.create(createProjectInput('Third')));

    // The unreadable file is left untouched for recovery.
    expect(fs.readFileSync(fixture.filePath, 'utf8')).toBe(corruptContent);
  });

  test('writes atomically without leaving a temp file behind', () => {
    createStore().create(createProjectInput('First'));

    expect(fs.existsSync(`${fixture.filePath}.tmp`)).toBe(false);
    expect(createStore().list()).toHaveLength(1);
  });

  test('mirrors every successful save to the backup file', () => {
    const store = createStore();
    store.create(createProjectInput('First'));
    store.create(createProjectInput('Second'));

    expect(store.hasBackup()).toBe(true);
    const backup = JSON.parse(fs.readFileSync(`${fixture.filePath}.bak`, 'utf8'));
    expect(backup.projects.map((project) => project.name)).toEqual(['First', 'Second']);
  });

  test('restoreFromBackup recovers all projects after corruption', () => {
    const store = createStore();
    store.create(createProjectInput('First'));
    store.create(createProjectInput('Second'));
    fs.writeFileSync(fixture.filePath, '{ this is not json');

    const restored = store.restoreFromBackup();

    expect(restored.map((project) => project.name)).toEqual(['First', 'Second']);
    expect(store.list().map((project) => project.name)).toEqual(['First', 'Second']);
  });

  test('restoreFromBackup fails closed when no backup exists', () => {
    fs.writeFileSync(fixture.filePath, '{ this is not json');
    const store = createStore();

    expect(store.hasBackup()).toBe(false);
    expectStoreCorrupt(() => store.restoreFromBackup());
  });

  test('restoreFromBackup fails closed when the backup is also unreadable', () => {
    const store = createStore();
    store.create(createProjectInput('First'));
    fs.writeFileSync(fixture.filePath, '{ this is not json');
    fs.writeFileSync(`${fixture.filePath}.bak`, '{ also not json');

    expectStoreCorrupt(() => store.restoreFromBackup());
  });

  test('startFresh moves the unreadable file aside and empties the store', () => {
    const store = createStore();
    store.create(createProjectInput('First'));
    const corruptContent = '{ this is not json';
    fs.writeFileSync(fixture.filePath, corruptContent);

    const { preservedPath } = store.startFresh();

    expect(preservedPath).toMatch(/projects\.json\.corrupt-/);
    expect(fs.readFileSync(preservedPath, 'utf8')).toBe(corruptContent);
    expect(store.list()).toEqual([]);
  });

  test('startFresh is a no-op when no file exists', () => {
    expect(createStore().startFresh()).toEqual({ preservedPath: null });
  });
});
