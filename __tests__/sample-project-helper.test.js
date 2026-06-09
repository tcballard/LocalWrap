const fs = require('fs');
const os = require('os');
const path = require('path');
const { ProjectStore } = require('../lib/projectStore');
const {
  SAMPLE_MARKER_FILE,
  copySampleProjectFiles,
  createSampleProject,
  getSampleDestinationPath,
  resolveSampleSourcePath,
} = require('../lib/sampleProject');

function createTempRoot() {
  return fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-sample-helper-'));
}

function createSampleSource(root) {
  const source = path.join(root, 'source-sample');
  fs.mkdirSync(source, { recursive: true });
  fs.writeFileSync(
    path.join(source, 'package.json'),
    `${JSON.stringify(
      {
        name: 'localwrap-sample-project',
        version: '1.0.0',
        private: true,
        scripts: {
          dev: 'node server.js',
          start: 'node server.js',
          preview: 'node server.js',
        },
      },
      null,
      2
    )}\n`
  );
  fs.writeFileSync(path.join(source, 'server.js'), "'use strict';\n");
  return source;
}

describe('sample project helper', () => {
  let root;

  beforeEach(() => {
    root = createTempRoot();
  });

  afterEach(() => {
    fs.rmSync(root, { recursive: true, force: true });
  });

  function createStore(userDataPath) {
    return new ProjectStore({
      filePath: path.join(userDataPath, 'projects.json'),
      idFactory: () => 'sample-project-id',
      now: () => '2026-06-08T00:00:00.000Z',
    });
  }

  test('resolves source path for development and packaged builds', () => {
    expect(resolveSampleSourcePath({ appRoot: '/repo/LocalWrap' })).toBe(
      path.join('/repo/LocalWrap', 'examples', 'sample-project')
    );
    expect(
      resolveSampleSourcePath({
        isPackaged: true,
        resourcesPath: '/Applications/LocalWrap.app/Contents/Resources',
      })
    ).toBe(path.join('/Applications/LocalWrap.app/Contents/Resources', 'sample-project'));
  });

  test('copies sample files into userData and writes the marker file', () => {
    const sourcePath = createSampleSource(root);
    const destinationPath = getSampleDestinationPath(path.join(root, 'userData'));

    const result = copySampleProjectFiles({
      sourcePath,
      destinationPath,
      now: () => '2026-06-08T00:00:00.000Z',
    });

    expect(result).toEqual({ copied: true, destinationPath });
    expect(fs.existsSync(path.join(destinationPath, 'package.json'))).toBe(true);
    expect(fs.existsSync(path.join(destinationPath, 'server.js'))).toBe(true);

    const marker = JSON.parse(
      fs.readFileSync(path.join(destinationPath, SAMPLE_MARKER_FILE), 'utf8')
    );
    expect(marker).toMatchObject({
      createdBy: 'LocalWrap',
      sample: 'localwrap-sample-project',
      markerVersion: 1,
      createdAt: '2026-06-08T00:00:00.000Z',
    });
  });

  test('creates a saved sample project with recommended defaults', async () => {
    const userDataPath = path.join(root, 'userData');
    const sourcePath = createSampleSource(root);
    const destinationPath = getSampleDestinationPath(userDataPath);
    const findAvailablePort = jest.fn(async () => 3456);
    const store = createStore(userDataPath);

    const project = await createSampleProject({
      projectStore: store,
      sourcePath,
      userDataPath,
      findAvailablePort,
      now: () => '2026-06-08T00:00:00.000Z',
    });

    expect(findAvailablePort).toHaveBeenCalledWith(3000);
    expect(project).toMatchObject({
      id: 'sample-project-id',
      name: 'localwrap-sample-project',
      cwd: destinationPath,
      command: 'npm run dev',
      port: 3456,
      url: 'http://localhost:3456',
      autostart: false,
      openOnReady: false,
      isSample: true,
    });
    expect(store.list()).toHaveLength(1);
  });

  test('returns an existing sample project instead of duplicating it', async () => {
    const userDataPath = path.join(root, 'userData');
    const sourcePath = createSampleSource(root);
    const store = createStore(userDataPath);
    const first = await createSampleProject({
      projectStore: store,
      sourcePath,
      userDataPath,
      findAvailablePort: jest.fn(async () => 3000),
    });
    const secondPortFinder = jest.fn(async () => 3001);

    const second = await createSampleProject({
      projectStore: store,
      sourcePath: path.join(root, 'missing-source'),
      userDataPath,
      findAvailablePort: secondPortFinder,
    });

    expect(second).toEqual(first);
    expect(secondPortFinder).not.toHaveBeenCalled();
    expect(store.list()).toHaveLength(1);
  });

  test('does not overwrite an unmarked destination directory', () => {
    const sourcePath = createSampleSource(root);
    const destinationPath = getSampleDestinationPath(path.join(root, 'userData'));
    fs.mkdirSync(destinationPath, { recursive: true });

    expect(() =>
      copySampleProjectFiles({
        sourcePath,
        destinationPath,
      })
    ).toThrow(/not marked/);
  });
});
