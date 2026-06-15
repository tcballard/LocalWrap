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

function normalizeWorkspace(workspace = {}) {
  const ids = Array.isArray(workspace.lastRunningProjectIds)
    ? workspace.lastRunningProjectIds.filter((id) => typeof id === 'string' && id.trim() !== '')
    : [];

  return {
    lastRunningProjectIds: Array.from(new Set(ids)),
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

class ProjectStore {
  constructor(options = {}) {
    if (!options.filePath) {
      throw new Error('ProjectStore requires a filePath.');
    }

    this.filePath = options.filePath;
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

    data.workspace = normalizeWorkspace({
      ...data.workspace,
      lastRunningProjectIds: nextIds,
      updatedAt: this.now(),
    });
    this.writeData(data);
    return data.workspace;
  }

  readData() {
    if (!this.fs.existsSync(this.filePath)) {
      return {
        projects: [],
        workspace: normalizeWorkspace(),
      };
    }

    try {
      const parsed = JSON.parse(this.fs.readFileSync(this.filePath, 'utf8'));
      return {
        projects: Array.isArray(parsed.projects) ? parsed.projects : [],
        workspace: normalizeWorkspace(parsed.workspace),
      };
    } catch (_error) {
      this.backupCorruptFile();
      return {
        projects: [],
        workspace: normalizeWorkspace(),
      };
    }
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
    const tempPath = `${this.filePath}.tmp-${process.pid}-${Date.now()}`;
    const payload = {
      projects: Array.isArray(data.projects) ? data.projects : [],
      workspace: normalizeWorkspace(data.workspace),
    };
    this.fs.writeFileSync(tempPath, `${JSON.stringify(payload, null, 2)}\n`);
    this.fs.renameSync(tempPath, this.filePath);
  }
}

module.exports = {
  ProjectStore,
  defaultNameFromDirectory,
  normalizeProjectInput,
  normalizeWorkspace,
};
