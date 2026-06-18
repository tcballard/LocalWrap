'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { normalizeProjectPort } = require('./portUtils');
const { validateScriptCommand } = require('./scriptValidation');
const { validateLocalProjectURL } = require('./urlValidation');

function nowIso() {
  return new Date().toISOString();
}

function defaultNameFromDirectory(cwd) {
  if (typeof cwd !== 'string' || cwd.trim() === '') {
    return 'Untitled Project';
  }
  return path.basename(cwd);
}

function ensureDirectory(cwd, fsImpl = fs) {
  if (typeof cwd !== 'string' || cwd.trim() === '') {
    throw new Error('Working directory is required.');
  }

  if (!fsImpl.existsSync(cwd) || !fsImpl.statSync(cwd).isDirectory()) {
    throw new Error(`Working directory does not exist: ${cwd}`);
  }
}

function normalizeWorkspaceProfile(profile, options = {}) {
  const validProjectIds = options.validProjectIds || null;
  const ids = Array.isArray(profile?.projectIds)
    ? profile.projectIds.filter(
        (id) =>
          typeof id === 'string' &&
          id.trim() !== '' &&
          (!validProjectIds || validProjectIds.has(id))
      )
    : [];
  const projectIds = Array.from(new Set(ids));

  if (!profile || typeof profile.id !== 'string' || profile.id.trim() === '') {
    return null;
  }

  if (projectIds.length === 0) {
    return null;
  }

  const name = String(profile.name || '').trim();
  return {
    id: profile.id,
    name: name || 'Workspace',
    projectIds,
    createdAt: typeof profile.createdAt === 'string' ? profile.createdAt : null,
    updatedAt: typeof profile.updatedAt === 'string' ? profile.updatedAt : null,
    lastStartedAt: typeof profile.lastStartedAt === 'string' ? profile.lastStartedAt : null,
  };
}

function normalizeWorkspace(workspace = {}, options = {}) {
  const validProjectIds = options.validProjectIds || null;
  const ids = Array.isArray(workspace.lastRunningProjectIds)
    ? workspace.lastRunningProjectIds.filter(
        (id) =>
          typeof id === 'string' &&
          id.trim() !== '' &&
          (!validProjectIds || validProjectIds.has(id))
      )
    : [];
  const profiles = Array.isArray(workspace.savedWorkspaces)
    ? workspace.savedWorkspaces
        .map((profile) => normalizeWorkspaceProfile(profile, { validProjectIds }))
        .filter(Boolean)
    : [];

  return {
    lastRunningProjectIds: Array.from(new Set(ids)),
    savedWorkspaces: profiles,
    updatedAt: typeof workspace.updatedAt === 'string' ? workspace.updatedAt : null,
  };
}

function normalizeProjectInput(input, existing, options = {}) {
  const fsImpl = options.fsImpl || fs;
  const now = options.now || nowIso;
  const idFactory = options.idFactory || crypto.randomUUID;
  const createdAt = existing?.createdAt || now();
  const updatedAt = now();
  const cwd = input.cwd ?? existing?.cwd;
  const command = input.command ?? existing?.command ?? 'npm start';
  const port = normalizeProjectPort(input.port ?? existing?.port ?? 3000);
  const url = input.url ?? existing?.url ?? `http://localhost:${port}`;

  ensureDirectory(cwd, fsImpl);
  validateScriptCommand(command);

  if (!validateLocalProjectURL(url)) {
    throw new Error('Project URL must be a local http(s) URL on an allowed port.');
  }

  const name = String(input.name ?? existing?.name ?? defaultNameFromDirectory(cwd)).trim();

  return {
    id: existing?.id || input.id || idFactory(),
    name: name || defaultNameFromDirectory(cwd),
    cwd,
    command: String(command).trim(),
    port,
    url,
    autostart: Boolean(input.autostart ?? existing?.autostart ?? false),
    openOnReady: Boolean(input.openOnReady ?? existing?.openOnReady ?? false),
    isSample: Boolean(input.isSample ?? existing?.isSample ?? false),
    createdAt,
    updatedAt,
  };
}

/**
 * Error thrown when the saved projects file exists but cannot be trusted
 * (unreadable, invalid JSON, or unexpected shape). Mutations refuse to run in
 * that state so a bad read can never cascade into overwriting user data.
 */
function storeCorruptError(message, cause) {
  const error = new Error(message);
  error.code = 'STORE_CORRUPT';
  if (cause) {
    error.cause = cause;
  }
  return error;
}

function isStoreCorruptError(error) {
  return Boolean(error) && error.code === 'STORE_CORRUPT';
}

class ProjectStore {
  constructor(options = {}) {
    if (!options.filePath) {
      throw new Error('ProjectStore requires a filePath.');
    }

    this.filePath = options.filePath;
    this.backupPath = options.backupPath || `${options.filePath}.bak`;
    this.fs = options.fsImpl || fs;
    this.now = options.now || nowIso;
    this.idFactory = options.idFactory || crypto.randomUUID;
  }

  list() {
    return this.readProjects();
  }

  get(id) {
    return this.readProjects().find((project) => project.id === id) || null;
  }

  create(input) {
    const projects = this.readProjects();
    const project = normalizeProjectInput(input, null, {
      fsImpl: this.fs,
      now: this.now,
      idFactory: this.idFactory,
    });

    projects.push(project);
    this.writeProjects(projects);
    return project;
  }

  update(id, patch) {
    const projects = this.readProjects();
    const index = projects.findIndex((project) => project.id === id);
    if (index === -1) {
      throw new Error('Project not found.');
    }

    const project = normalizeProjectInput({ ...projects[index], ...patch, id }, projects[index], {
      fsImpl: this.fs,
      now: this.now,
      idFactory: this.idFactory,
    });

    projects[index] = project;
    this.writeProjects(projects);
    return project;
  }

  delete(id) {
    const projects = this.readProjects();
    const nextProjects = projects.filter((project) => project.id !== id);
    if (nextProjects.length === projects.length) {
      throw new Error('Project not found.');
    }

    this.writeProjects(nextProjects);
    return true;
  }

  readProjects() {
    return this.readData().projects;
  }

  getWorkspace() {
    return this.readData().workspace;
  }

  setLastRunningProjectIds(projectIds = []) {
    const data = this.readData();
    const validProjectIds = new Set(data.projects.map((project) => project.id));
    const nextIds = Array.from(
      new Set(projectIds.filter((id) => typeof id === 'string' && validProjectIds.has(id)))
    );

    data.workspace = normalizeWorkspace(
      {
        ...data.workspace,
        lastRunningProjectIds: nextIds,
        updatedAt: this.now(),
      },
      { validProjectIds }
    );
    this.writeData(data);
    return data.workspace;
  }

  saveWorkspaceProfile(input = {}) {
    const data = this.readData();
    const validProjectIds = new Set(data.projects.map((project) => project.id));
    const projectIds = Array.from(
      new Set(
        (Array.isArray(input.projectIds) ? input.projectIds : []).filter(
          (id) => typeof id === 'string' && validProjectIds.has(id)
        )
      )
    );

    if (projectIds.length === 0) {
      throw new Error('A workspace needs at least one saved project.');
    }

    const now = this.now();
    const profiles = data.workspace.savedWorkspaces || [];
    const existingIndex = profiles.findIndex((profile) => profile.id === input.id);
    const existing = existingIndex >= 0 ? profiles[existingIndex] : null;
    const profile = {
      id: existing?.id || input.id || this.idFactory(),
      name: String(input.name || existing?.name || 'Workspace').trim() || 'Workspace',
      projectIds,
      createdAt: existing?.createdAt || now,
      updatedAt: now,
      lastStartedAt: existing?.lastStartedAt || null,
    };

    if (existingIndex >= 0) {
      profiles[existingIndex] = profile;
    } else {
      profiles.push(profile);
    }

    data.workspace = normalizeWorkspace(
      {
        ...data.workspace,
        savedWorkspaces: profiles,
        updatedAt: now,
      },
      { validProjectIds }
    );
    this.writeData(data);
    return profile;
  }

  markWorkspaceProfileStarted(profileId) {
    const data = this.readData();
    const validProjectIds = new Set(data.projects.map((project) => project.id));
    const profiles = data.workspace.savedWorkspaces || [];
    const profile = profiles.find((candidate) => candidate.id === profileId);
    if (!profile) {
      throw new Error('Workspace not found.');
    }

    const now = this.now();
    profile.lastStartedAt = now;
    profile.updatedAt = now;
    data.workspace = normalizeWorkspace(
      {
        ...data.workspace,
        savedWorkspaces: profiles,
        updatedAt: now,
      },
      { validProjectIds }
    );
    this.writeData(data);
    return data.workspace.savedWorkspaces.find((candidate) => candidate.id === profileId);
  }

  readData(filePath = this.filePath) {
    if (!this.fs.existsSync(filePath)) {
      return {
        projects: [],
        workspace: normalizeWorkspace(),
      };
    }

    let raw;
    try {
      raw = this.fs.readFileSync(filePath, 'utf8');
    } catch (error) {
      throw storeCorruptError(`Saved projects file could not be read: ${error.message}`, error);
    }

    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (error) {
      throw storeCorruptError('Saved projects file is not valid JSON.', error);
    }

    if (!parsed || !Array.isArray(parsed.projects)) {
      throw storeCorruptError('Saved projects file has an unexpected format.');
    }

    const validProjectIds = new Set(parsed.projects.map((project) => project.id));
    return {
      projects: parsed.projects,
      workspace: normalizeWorkspace(parsed.workspace, { validProjectIds }),
    };
  }

  readProjectsFile(filePath) {
    return this.readData(filePath).projects;
  }

  backupCorruptFile() {
    if (!this.fs.existsSync(this.filePath)) {
      return null;
    }

    const backupPath = `${this.filePath}.corrupt-${this.now().replace(/[:.]/g, '-')}`;
    this.fs.copyFileSync(this.filePath, backupPath);
    return backupPath;
  }

  writeProjects(projects) {
    const data = this.readData();
    this.writeData({
      ...data,
      projects,
    });
  }

  writeData(data) {
    this.fs.mkdirSync(path.dirname(this.filePath), { recursive: true });

    // Atomic: a crash mid-write leaves either the old file or the new one,
    // never a truncated mix.
    const tempPath = `${this.filePath}.tmp`;
    const payload = {
      projects: Array.isArray(data.projects) ? data.projects : [],
    };
    const validProjectIds = new Set(payload.projects.map((project) => project.id));
    payload.workspace = normalizeWorkspace(data.workspace, { validProjectIds });
    this.fs.writeFileSync(tempPath, `${JSON.stringify(payload, null, 2)}\n`);
    this.fs.renameSync(tempPath, this.filePath);

    // Mirror the last successful write so external corruption is recoverable.
    // Best-effort: a failed backup must not fail the save itself.
    try {
      this.fs.copyFileSync(this.filePath, this.backupPath);
    } catch (_error) {
      // ignored
    }
  }

  hasBackup() {
    return this.fs.existsSync(this.backupPath);
  }

  /**
   * Replace an unreadable projects file with the last known-good backup.
   * Throws STORE_CORRUPT if the backup is missing or also unreadable.
   */
  restoreFromBackup() {
    if (!this.hasBackup()) {
      throw storeCorruptError('No backup of the saved projects file exists.');
    }

    const projects = this.readProjectsFile(this.backupPath);
    const tempPath = `${this.filePath}.tmp`;
    this.fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
    this.fs.copyFileSync(this.backupPath, tempPath);
    this.fs.renameSync(tempPath, this.filePath);
    return projects;
  }

  /**
   * Abandon an unreadable projects file by moving it aside (never deleting
   * user data) so the store reads as empty again.
   *
   * @returns {{ preservedPath: string|null }} where the old file was kept.
   */
  startFresh() {
    if (!this.fs.existsSync(this.filePath)) {
      return { preservedPath: null };
    }

    // ISO timestamps contain characters that are invalid in Windows filenames.
    const stamp = this.now().replace(/[:.]/g, '-');
    const preservedPath = `${this.filePath}.corrupt-${stamp}`;
    this.fs.renameSync(this.filePath, preservedPath);
    return { preservedPath };
  }
}

module.exports = {
  ProjectStore,
  defaultNameFromDirectory,
  isStoreCorruptError,
  normalizeProjectInput,
  normalizeWorkspaceProfile,
  normalizeWorkspace,
};
