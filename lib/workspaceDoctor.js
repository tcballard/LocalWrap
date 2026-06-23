'use strict';

const fs = require('fs');
const path = require('path');
const { getDependencyWarning } = require('./projectDoctor');
const { isValidProjectPort, parsePort } = require('./portUtils');
const { validateProjectDraft } = require('./projectValidation');

const WORKSPACE_DOCTOR_CHECKS = [
  ['projects', 'Projects'],
  ['directories', 'Directories'],
  ['commands', 'Commands'],
  ['dependencies', 'Dependencies'],
  ['env', 'Environment'],
  ['ports', 'Ports'],
  ['urls', 'URLs'],
];

const FIELD_TO_CHECK = {
  name: 'projects',
  cwd: 'directories',
  command: 'commands',
  dependencies: 'dependencies',
  env: 'env',
  port: 'ports',
  url: 'urls',
};

function nowIso() {
  return new Date().toISOString();
}

function createCheck(id, label, status = 'pending', message = 'Not checked yet.') {
  return {
    id,
    label,
    status,
    message,
  };
}

function parseEnvKeys(contents = '') {
  const keys = new Set();
  String(contents)
    .split(/\r?\n/)
    .forEach((line) => {
      const match = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/);
      if (match) {
        keys.add(match[1]);
      }
    });
  return keys;
}

function readEnvKeys(filePath, fsImpl = fs) {
  if (!fsImpl.existsSync(filePath)) {
    return null;
  }

  try {
    return parseEnvKeys(fsImpl.readFileSync(filePath, 'utf8'));
  } catch (_error) {
    return null;
  }
}

function getEnvWarning(cwd, fsImpl = fs) {
  if (!cwd || !fsImpl.existsSync(cwd) || !fsImpl.statSync(cwd).isDirectory()) {
    return null;
  }

  const examplePath = path.join(cwd, '.env.example');
  const expectedKeys = readEnvKeys(examplePath, fsImpl);
  if (!expectedKeys || expectedKeys.size === 0) {
    return null;
  }

  const actualKeys = readEnvKeys(path.join(cwd, '.env'), fsImpl);
  const missingKeys = actualKeys
    ? Array.from(expectedKeys).filter((key) => !actualKeys.has(key))
    : Array.from(expectedKeys);

  if (missingKeys.length === 0) {
    return null;
  }

  const preview = missingKeys.slice(0, 3).join(', ');
  const suffix = missingKeys.length > 3 ? `, +${missingKeys.length - 3} more` : '';
  return {
    field: 'env',
    code: actualKeys ? 'env-vars-missing' : 'env-file-missing',
    message: actualKeys
      ? `Missing env value(s): ${preview}${suffix}.`
      : `Missing .env for ${missingKeys.length} expected value(s): ${preview}${suffix}.`,
    missingKeys,
  };
}

function createIssue(severity, field, code, message) {
  return {
    severity,
    field,
    code,
    message,
  };
}

function getProjectIdsForWorkspace(projects = [], workspace = {}, profileId = null) {
  const savedIds = new Set(projects.map((project) => project.id));

  if (profileId) {
    const profile = (workspace.savedWorkspaces || []).find(
      (candidate) => candidate.id === profileId
    );
    if (!profile) {
      throw new Error('Workspace not found.');
    }
    return {
      kind: 'profile',
      profileId: profile.id,
      name: profile.name,
      projectIds: (profile.projectIds || []).filter((projectId) => savedIds.has(projectId)),
    };
  }

  const lastRunningProjectIds = (workspace.lastRunningProjectIds || []).filter((projectId) =>
    savedIds.has(projectId)
  );
  if (lastRunningProjectIds.length > 0) {
    return {
      kind: 'last-running',
      profileId: null,
      name: 'Last running workspace',
      projectIds: lastRunningProjectIds,
    };
  }

  return {
    kind: 'all-projects',
    profileId: null,
    name: 'Saved projects',
    projectIds: projects.map((project) => project.id),
  };
}

async function analyzeProject(project, options = {}) {
  const fsImpl = options.fsImpl || fs;
  const issues = [];
  const validation = await (options.validateProjectDraft || validateProjectDraft)(project, {
    fsImpl,
    checkAvailability: false,
  });

  validation.errors.forEach((error) => {
    issues.push(createIssue('fail', error.field, error.code, error.message));
  });
  validation.warnings.forEach((warning) => {
    issues.push(createIssue('warn', warning.field, warning.code, warning.message));
  });

  const dependencyWarning = getDependencyWarning(project.cwd, fsImpl);
  if (dependencyWarning) {
    issues.push(
      createIssue('warn', 'dependencies', dependencyWarning.code, dependencyWarning.message)
    );
  }

  const envWarning = getEnvWarning(project.cwd, fsImpl);
  if (envWarning) {
    issues.push(createIssue('warn', 'env', envWarning.code, envWarning.message));
  }

  return {
    id: project.id,
    name: project.name || 'Untitled Project',
    port: project.port,
    url: project.url,
    issues,
  };
}

function addDuplicatePortIssues(projectAnalyses) {
  const byPort = new Map();
  projectAnalyses.forEach((project) => {
    const port = parsePort(project.port);
    if (!isValidProjectPort(port)) {
      return;
    }
    if (!byPort.has(port)) {
      byPort.set(port, []);
    }
    byPort.get(port).push(project);
  });

  byPort.forEach((projects, port) => {
    if (projects.length <= 1) {
      return;
    }
    const names = projects.map((project) => project.name).join(', ');
    projects.forEach((project) => {
      project.issues.push(
        createIssue(
          'fail',
          'port',
          'port-duplicate',
          `Port ${port} is assigned to multiple projects: ${names}.`
        )
      );
    });
  });
}

async function addBusyPortIssues(projectAnalyses, options = {}) {
  const checkPortAvailable = options.checkPortAvailable;
  if (!checkPortAvailable) {
    return;
  }

  await Promise.all(
    projectAnalyses.map(async (project) => {
      const port = parsePort(project.port);
      if (!isValidProjectPort(port)) {
        return;
      }
      const alreadyHasDuplicate = project.issues.some((issue) => issue.code === 'port-duplicate');
      if (alreadyHasDuplicate) {
        return;
      }
      const available = await checkPortAvailable(port);
      if (!available) {
        project.issues.push(
          createIssue('warn', 'port', 'port-busy', `Port ${port} appears to be in use.`)
        );
      }
    })
  );
}

function issueCheckId(issue) {
  return FIELD_TO_CHECK[issue.field] || 'projects';
}

function projectStatus(issues) {
  if (issues.some((issue) => issue.severity === 'fail')) {
    return 'blocked';
  }
  if (issues.some((issue) => issue.severity === 'warn')) {
    return 'attention';
  }
  return 'ready';
}

function projectSummary(issues) {
  const firstFailure = issues.find((issue) => issue.severity === 'fail');
  if (firstFailure) {
    return firstFailure.message;
  }
  const firstWarning = issues.find((issue) => issue.severity === 'warn');
  if (firstWarning) {
    return firstWarning.message;
  }
  return 'Ready to start.';
}

function summarizeCheck(checkId, label, projects) {
  const issues = projects.flatMap((project) =>
    project.issues.filter((issue) => issueCheckId(issue) === checkId)
  );
  const failures = issues.filter((issue) => issue.severity === 'fail');
  const warnings = issues.filter((issue) => issue.severity === 'warn');

  if (failures.length > 0) {
    return createCheck(checkId, label, 'fail', `${failures.length} blocker(s) found.`);
  }
  if (warnings.length > 0) {
    return createCheck(checkId, label, 'warn', `${warnings.length} warning(s) found.`);
  }

  return createCheck(checkId, label, 'pass', 'Ready.');
}

function finalizeProjects(projects) {
  return projects.map((project) => ({
    ...project,
    status: projectStatus(project.issues),
    summary: projectSummary(project.issues),
  }));
}

function createEmptyDiagnosis(target, now) {
  return {
    status: 'empty',
    summary: 'No saved projects to diagnose. Next: import a workspace pack or add a project.',
    updatedAt: now(),
    target,
    totals: {
      projects: 0,
      ready: 0,
      warnings: 0,
      blockers: 0,
    },
    startableProjectIds: [],
    blockedProjectIds: [],
    checks: WORKSPACE_DOCTOR_CHECKS.map(([id, label]) =>
      createCheck(id, label, id === 'projects' ? 'fail' : 'pending', 'No projects selected.')
    ),
    projects: [],
  };
}

async function diagnoseWorkspace(input = {}, options = {}) {
  const now = options.now || nowIso;
  const projects = Array.isArray(input.projects) ? input.projects : [];
  const workspace = input.workspace || {};
  const target = getProjectIdsForWorkspace(projects, workspace, input.profileId || null);
  const projectById = new Map(projects.map((project) => [project.id, project]));
  const targetProjects = target.projectIds
    .map((projectId) => projectById.get(projectId))
    .filter(Boolean);

  if (targetProjects.length === 0) {
    return createEmptyDiagnosis(target, now);
  }

  const analyzedProjects = await Promise.all(
    targetProjects.map((project) => analyzeProject(project, options))
  );
  addDuplicatePortIssues(analyzedProjects);
  await addBusyPortIssues(analyzedProjects, options);

  const finalizedProjects = finalizeProjects(analyzedProjects);
  const blockerCount = finalizedProjects.filter((project) => project.status === 'blocked').length;
  const warningCount = finalizedProjects.filter((project) => project.status === 'attention').length;
  const readyCount = finalizedProjects.filter((project) => project.status === 'ready').length;
  const status = blockerCount > 0 ? 'blocked' : warningCount > 0 ? 'attention' : 'ready';
  const checks = WORKSPACE_DOCTOR_CHECKS.map(([id, label]) => {
    if (id === 'projects') {
      return createCheck(id, label, 'pass', `${targetProjects.length} project(s) selected.`);
    }
    return summarizeCheck(id, label, finalizedProjects);
  });
  const startableProjectIds = finalizedProjects
    .filter((project) => project.status !== 'blocked')
    .map((project) => project.id);
  const blockedProjectIds = finalizedProjects
    .filter((project) => project.status === 'blocked')
    .map((project) => project.id);

  const summary =
    status === 'blocked'
      ? `${blockerCount} project(s) blocked before first green run.`
      : status === 'attention'
        ? `${warningCount} project(s) need attention before first green run.`
        : 'Workspace looks ready to start.';

  return {
    status,
    summary,
    updatedAt: now(),
    target,
    totals: {
      projects: finalizedProjects.length,
      ready: readyCount,
      warnings: warningCount,
      blockers: blockerCount,
    },
    startableProjectIds,
    blockedProjectIds,
    checks,
    projects: finalizedProjects,
  };
}

module.exports = {
  WORKSPACE_DOCTOR_CHECKS,
  diagnoseWorkspace,
  getEnvWarning,
  getProjectIdsForWorkspace,
  parseEnvKeys,
};
