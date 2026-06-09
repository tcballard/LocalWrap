'use strict';

const fs = require('fs');
const path = require('path');
const { findAvailablePort } = require('./portUtils');
const { inspectProjectDirectory } = require('./projectInspection');

const SAMPLE_RESOURCE_DIR = 'sample-project';
const SAMPLE_PROJECTS_DIR = 'sample-projects';
const SAMPLE_PROJECT_DIR = 'localwrap-sample-project';
const SAMPLE_MARKER_FILE = '.localwrap-sample.json';
const SAMPLE_MARKER_VERSION = 1;

function resolveSampleSourcePath(options = {}) {
  const isPackaged = Boolean(options.isPackaged);
  const appRoot = options.appRoot || path.join(__dirname, '..');
  const resourcesPath = options.resourcesPath || process.resourcesPath;

  if (isPackaged) {
    if (!resourcesPath) {
      throw new Error('Packaged sample project resources are unavailable.');
    }

    return path.join(resourcesPath, SAMPLE_RESOURCE_DIR);
  }

  return path.join(appRoot, 'examples', SAMPLE_RESOURCE_DIR);
}

function getSampleDestinationPath(userDataPath) {
  if (typeof userDataPath !== 'string' || userDataPath.trim() === '') {
    throw new Error('User data path is required.');
  }

  return path.join(userDataPath, SAMPLE_PROJECTS_DIR, SAMPLE_PROJECT_DIR);
}

function getSampleMarkerPath(destinationPath) {
  return path.join(destinationPath, SAMPLE_MARKER_FILE);
}

function samePath(left, right) {
  if (!left || !right) {
    return false;
  }

  return path.resolve(left) === path.resolve(right);
}

function isMarkedSampleDirectory(destinationPath, fsImpl = fs) {
  return fsImpl.existsSync(getSampleMarkerPath(destinationPath));
}

function copyRecursive(sourcePath, destinationPath, fsImpl) {
  const stat = fsImpl.statSync(sourcePath);
  if (!stat.isDirectory()) {
    fsImpl.copyFileSync(sourcePath, destinationPath);
    return;
  }

  fsImpl.mkdirSync(destinationPath, { recursive: true });
  for (const entry of fsImpl.readdirSync(sourcePath, { withFileTypes: true })) {
    copyRecursive(
      path.join(sourcePath, entry.name),
      path.join(destinationPath, entry.name),
      fsImpl
    );
  }
}

function writeSampleMarker(destinationPath, options = {}) {
  const fsImpl = options.fsImpl || fs;
  const now = options.now || (() => new Date().toISOString());
  const marker = {
    createdBy: 'LocalWrap',
    sample: SAMPLE_PROJECT_DIR,
    markerVersion: SAMPLE_MARKER_VERSION,
    createdAt: now(),
  };

  fsImpl.writeFileSync(
    getSampleMarkerPath(destinationPath),
    `${JSON.stringify(marker, null, 2)}\n`
  );
}

function copySampleProjectFiles(options = {}) {
  const fsImpl = options.fsImpl || fs;
  const sourcePath = options.sourcePath;
  const destinationPath = options.destinationPath;

  if (!sourcePath || !fsImpl.existsSync(sourcePath) || !fsImpl.statSync(sourcePath).isDirectory()) {
    throw new Error(`Sample project source does not exist: ${sourcePath}`);
  }

  if (fsImpl.existsSync(destinationPath)) {
    if (!fsImpl.statSync(destinationPath).isDirectory()) {
      throw new Error(`Sample project destination is not a directory: ${destinationPath}`);
    }

    if (!isMarkedSampleDirectory(destinationPath, fsImpl)) {
      throw new Error(
        'Sample project destination already exists but is not marked as a LocalWrap sample.'
      );
    }

    return { copied: false, destinationPath };
  }

  fsImpl.mkdirSync(path.dirname(destinationPath), { recursive: true });
  copyRecursive(sourcePath, destinationPath, fsImpl);
  writeSampleMarker(destinationPath, {
    fsImpl,
    now: options.now,
  });

  return { copied: true, destinationPath };
}

function findExistingSampleProject(projects, destinationPath, fsImpl = fs) {
  return (
    projects.find(
      (project) =>
        project?.isSample ||
        (samePath(project?.cwd, destinationPath) &&
          isMarkedSampleDirectory(destinationPath, fsImpl))
    ) || null
  );
}

async function createSampleProject(options = {}) {
  const projectStore = options.projectStore;
  if (!projectStore) {
    throw new Error('ProjectStore is required.');
  }

  const fsImpl = options.fsImpl || fs;
  const app = options.app;
  const userDataPath = options.userDataPath || app?.getPath?.('userData');
  const destinationPath = options.destinationPath || getSampleDestinationPath(userDataPath || '');
  const existing = findExistingSampleProject(projectStore.list(), destinationPath, fsImpl);

  if (existing) {
    return existing;
  }

  const isPackaged = options.isPackaged ?? Boolean(app?.isPackaged);
  const sourcePath =
    options.sourcePath ||
    resolveSampleSourcePath({
      appRoot: options.appRoot,
      isPackaged,
      resourcesPath: options.resourcesPath,
    });

  copySampleProjectFiles({
    fsImpl,
    sourcePath,
    destinationPath,
    now: options.now,
  });

  const inspect = options.inspectProjectDirectory || inspectProjectDirectory;
  const findPort = options.findAvailablePort || findAvailablePort;
  const profile = await inspect(destinationPath, {
    preferredPort: 3000,
    findAvailablePort: findPort,
  });
  const port = profile.suggestedPort || (await findPort(3000));

  return projectStore.create({
    name: profile.name || SAMPLE_PROJECT_DIR,
    cwd: destinationPath,
    command: profile.recommendedCommand || 'npm run dev',
    port,
    url: `http://localhost:${port}`,
    autostart: false,
    openOnReady: false,
    isSample: true,
  });
}

module.exports = {
  SAMPLE_MARKER_FILE,
  SAMPLE_PROJECT_DIR,
  SAMPLE_PROJECTS_DIR,
  SAMPLE_RESOURCE_DIR,
  copySampleProjectFiles,
  createSampleProject,
  findExistingSampleProject,
  getSampleDestinationPath,
  getSampleMarkerPath,
  isMarkedSampleDirectory,
  resolveSampleSourcePath,
};
