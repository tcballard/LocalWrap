const fs = require('fs');
const os = require('os');
const path = require('path');
const { ProjectStore } = require('../lib/projectStore');

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
