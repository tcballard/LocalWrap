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
    if (!this.fs.existsSync(this.filePath)) {
      return [];
    }

    try {
      const parsed = JSON.parse(this.fs.readFileSync(this.filePath, 'utf8'));
      return Array.isArray(parsed.projects) ? parsed.projects : [];
    } catch (_error) {
      return [];
    }
  }

  writeProjects(projects) {
    this.fs.mkdirSync(path.dirname(this.filePath), { recursive: true });
    this.fs.writeFileSync(this.filePath, `${JSON.stringify({ projects }, null, 2)}\n`);
  }
}

module.exports = {
  ProjectStore,
  defaultNameFromDirectory,
  normalizeProjectInput,
};
