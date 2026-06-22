'use strict';

const fs = require('fs');
const path = require('path');
const { normalizeProjectPort } = require('./portUtils');
const { validateScriptCommand } = require('./scriptValidation');
const { validateLocalProjectURL } = require('./urlValidation');

const WORKSPACE_PACK_VERSION = 1;
const WORKSPACE_PACK_DIR = '.localwrap';
const WORKSPACE_PACK_FILENAME = 'workspace.json';
const WORKSPACE_PACK_CANDIDATES = [
  path.join(WORKSPACE_PACK_DIR, WORKSPACE_PACK_FILENAME),
  'localwrap.json',
];

function isObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

function slugify(value, fallback = 'item') {
  const slug = String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return slug || fallback;
}

function uniqueSlug(base, used) {
  const root = slugify(base);
  let candidate = root;
  let suffix = 2;
  while (used.has(candidate)) {
    candidate = `${root}-${suffix++}`;
  }
  used.add(candidate);
  return candidate;
}

function assertDirectory(rootDir, fsImpl = fs) {
  if (typeof rootDir !== 'string' || rootDir.trim() === '') {
    throw new Error('Workspace folder is required.');
  }
  if (!fsImpl.existsSync(rootDir) || !fsImpl.statSync(rootDir).isDirectory()) {
    throw new Error(`Workspace folder does not exist: ${rootDir}`);
  }
}

function resolveProjectPath(rootDir, relativePath) {
  const cleanPath = String(relativePath || '.').trim() || '.';
  if (path.isAbsolute(cleanPath)) {
    throw new Error('Workspace project paths must be relative.');
  }

  const cwd = path.resolve(rootDir, cleanPath);
  const relative = path.relative(rootDir, cwd);
  if (relative === '..' || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    throw new Error(`Workspace project path escapes the workspace folder: ${cleanPath}`);
  }

  return {
    cwd,
    path: relative || '.',
  };
}

function isInsideDirectory(rootDir, targetPath) {
  const relative = path.relative(rootDir, targetPath);
  return relative === '' || (!relative.startsWith('..') && !path.isAbsolute(relative));
}

function normalizePackProject(project, index, options = {}) {
  if (!isObject(project)) {
    throw new Error(`Workspace project ${index + 1} must be an object.`);
  }

  const rawId = String(project.id || project.name || `project-${index + 1}`).trim();
  const id = slugify(rawId, `project-${index + 1}`);
  const name = String(project.name || rawId || `Project ${index + 1}`).trim();
  const { cwd, path: relativePath } = resolveProjectPath(options.rootDir, project.path || '.');
  const command = String(project.command || '').trim();
  validateScriptCommand(command);

  const port = normalizeProjectPort(project.port || 3000);
  const url = String(project.url || `http://localhost:${port}`).trim();
  if (!validateLocalProjectURL(url)) {
    throw new Error(`Workspace project "${name}" must use a local http(s) URL.`);
  }

  return {
    id,
    name: name || rawId || `Project ${index + 1}`,
    path: relativePath,
    cwd,
    command,
    port,
    url,
    autostart: Boolean(project.autostart),
    openOnReady: project.openOnReady !== false,
  };
}

function normalizePackWorkspace(workspace, index, projectIds, projectIdAliases = new Map()) {
  if (!isObject(workspace)) {
    throw new Error(`Workspace profile ${index + 1} must be an object.`);
  }

  const rawId = String(workspace.id || workspace.name || `workspace-${index + 1}`).trim();
  const id = slugify(rawId, `workspace-${index + 1}`);
  const name = String(workspace.name || rawId || `Workspace ${index + 1}`).trim();
  const ids = Array.isArray(workspace.projects) ? workspace.projects : workspace.projectIds;
  const includedProjectIds = Array.isArray(ids)
    ? Array.from(
        new Set(
          ids
            .map((projectId) => {
              const rawProjectId = String(projectId || '').trim();
              return projectIdAliases.get(rawProjectId) || rawProjectId;
            })
            .filter((projectId) => projectIds.has(projectId))
        )
      )
    : [];

  if (includedProjectIds.length === 0) {
    return null;
  }

  return {
    id,
    name: name || 'Workspace',
    projects: includedProjectIds,
  };
}

function normalizeWorkspacePack(rawPack, options = {}) {
  const rootDir = options.rootDir ? path.resolve(options.rootDir) : null;
  if (!rootDir) {
    throw new Error('Workspace root is required.');
  }

  if (!isObject(rawPack)) {
    throw new Error('Workspace pack must be a JSON object.');
  }

  const version = Number(rawPack.localwrap || rawPack.version || WORKSPACE_PACK_VERSION);
  if (version !== WORKSPACE_PACK_VERSION) {
    throw new Error(`Unsupported LocalWrap workspace pack version: ${version}`);
  }

  if (!Array.isArray(rawPack.projects) || rawPack.projects.length === 0) {
    throw new Error('Workspace pack needs at least one project.');
  }

  const usedProjectIds = new Set();
  const projectIdAliases = new Map();
  const projects = rawPack.projects.map((project, index) => {
    const normalized = normalizePackProject(project, index, { rootDir });
    const uniqueId = uniqueSlug(normalized.id, usedProjectIds);
    [normalized.id, project?.id, project?.name, uniqueId].forEach((alias) => {
      const trimmed = typeof alias === 'string' ? alias.trim() : '';
      if (trimmed && !projectIdAliases.has(trimmed)) {
        projectIdAliases.set(trimmed, uniqueId);
      }
    });
    return {
      ...normalized,
      id: uniqueId,
    };
  });
  const projectIds = new Set(projects.map((project) => project.id));
  const declaredWorkspaces = Array.isArray(rawPack.workspaces) ? rawPack.workspaces : [];
  const workspaces = declaredWorkspaces
    .map((workspace, index) =>
      normalizePackWorkspace(workspace, index, projectIds, projectIdAliases)
    )
    .filter(Boolean);

  if (workspaces.length === 0) {
    workspaces.push({
      id: 'default',
      name: String(rawPack.name || path.basename(rootDir) || 'Workspace').trim() || 'Workspace',
      projects: projects.map((project) => project.id),
    });
  }

  return {
    localwrap: WORKSPACE_PACK_VERSION,
    name: String(rawPack.name || path.basename(rootDir) || 'Workspace').trim() || 'Workspace',
    rootDir,
    packPath: options.packPath || null,
    projects,
    workspaces,
  };
}

function findWorkspacePack(rootDir, options = {}) {
  const fsImpl = options.fsImpl || fs;
  const resolvedRoot = path.resolve(rootDir);
  assertDirectory(resolvedRoot, fsImpl);

  for (const candidate of WORKSPACE_PACK_CANDIDATES) {
    const packPath = path.join(resolvedRoot, candidate);
    if (fsImpl.existsSync(packPath) && fsImpl.statSync(packPath).isFile()) {
      return packPath;
    }
  }

  return null;
}

function readWorkspacePack(rootDir, options = {}) {
  const fsImpl = options.fsImpl || fs;
  const resolvedRoot = path.resolve(rootDir);
  const packPath = options.packPath || findWorkspacePack(resolvedRoot, { fsImpl });
  if (!packPath) {
    throw new Error('No LocalWrap workspace pack found in that folder.');
  }

  let parsed;
  try {
    parsed = JSON.parse(fsImpl.readFileSync(packPath, 'utf8'));
  } catch (error) {
    throw new Error(`Workspace pack is not valid JSON: ${error.message}`, { cause: error });
  }

  return normalizeWorkspacePack(parsed, {
    rootDir: resolvedRoot,
    packPath,
  });
}

function summarizeWorkspacePack(pack) {
  return {
    name: pack.name,
    packPath: pack.packPath,
    rootDir: pack.rootDir,
    projects: pack.projects.map((project) => ({
      id: project.id,
      name: project.name,
      path: project.path,
      cwd: project.cwd,
      command: project.command,
      port: project.port,
      url: project.url,
    })),
    workspaces: pack.workspaces.map((workspace) => ({
      id: workspace.id,
      name: workspace.name,
      projects: workspace.projects,
    })),
  };
}

function projectSourceProjectId(project) {
  if (project.source?.type === 'workspace-pack' && project.source.packProjectId) {
    return project.source.packProjectId;
  }
  return null;
}

function workspaceSourceWorkspaceId(workspace) {
  if (workspace.source?.type === 'workspace-pack' && workspace.source.packWorkspaceId) {
    return workspace.source.packWorkspaceId;
  }
  return null;
}

function buildWorkspacePack({ rootDir, projects = [], workspace = {}, name }) {
  const resolvedRoot = path.resolve(rootDir);
  assertDirectory(resolvedRoot);
  const usedProjectIds = new Set();
  const skippedProjects = [];
  const projectIdMap = new Map();
  const packProjects = [];

  projects.forEach((project) => {
    const cwd = path.resolve(project.cwd || '');
    if (!project.cwd || !isInsideDirectory(resolvedRoot, cwd)) {
      skippedProjects.push({
        id: project.id,
        name: project.name || 'Untitled Project',
        reason: 'outside-workspace-folder',
      });
      return;
    }

    const relative = path.relative(resolvedRoot, cwd) || '.';
    const packProjectId = uniqueSlug(
      projectSourceProjectId(project) || project.name || project.id,
      usedProjectIds
    );
    projectIdMap.set(project.id, packProjectId);
    packProjects.push({
      id: packProjectId,
      name: project.name,
      path: relative,
      command: project.command,
      port: project.port,
      url: project.url,
      autostart: Boolean(project.autostart),
      openOnReady: Boolean(project.openOnReady),
    });
  });

  if (packProjects.length === 0) {
    throw new Error('No saved projects live inside that workspace folder.');
  }

  const usedWorkspaceIds = new Set();
  const packWorkspaces = [];
  (workspace.savedWorkspaces || []).forEach((profile) => {
    const projectsForProfile = (profile.projectIds || [])
      .map((projectId) => projectIdMap.get(projectId))
      .filter(Boolean);
    if (projectsForProfile.length === 0) {
      return;
    }

    const packWorkspaceId = uniqueSlug(
      workspaceSourceWorkspaceId(profile) || profile.name || profile.id,
      usedWorkspaceIds
    );
    packWorkspaces.push({
      id: packWorkspaceId,
      name: profile.name,
      projects: Array.from(new Set(projectsForProfile)),
    });
  });

  if (packWorkspaces.length === 0) {
    packWorkspaces.push({
      id: 'default',
      name: name || path.basename(resolvedRoot) || 'Workspace',
      projects: packProjects.map((project) => project.id),
    });
  }

  return {
    pack: {
      localwrap: WORKSPACE_PACK_VERSION,
      name: name || path.basename(resolvedRoot) || 'Workspace',
      projects: packProjects,
      workspaces: packWorkspaces,
    },
    skippedProjects,
  };
}

function writeWorkspacePack(rootDir, pack, options = {}) {
  const fsImpl = options.fsImpl || fs;
  const resolvedRoot = path.resolve(rootDir);
  assertDirectory(resolvedRoot, fsImpl);
  const packPath = path.join(resolvedRoot, WORKSPACE_PACK_DIR, WORKSPACE_PACK_FILENAME);
  fsImpl.mkdirSync(path.dirname(packPath), { recursive: true });
  fsImpl.writeFileSync(packPath, `${JSON.stringify(pack, null, 2)}\n`);
  return packPath;
}

module.exports = {
  WORKSPACE_PACK_CANDIDATES,
  WORKSPACE_PACK_FILENAME,
  WORKSPACE_PACK_VERSION,
  buildWorkspacePack,
  findWorkspacePack,
  normalizeWorkspacePack,
  readWorkspacePack,
  summarizeWorkspacePack,
  writeWorkspacePack,
};
