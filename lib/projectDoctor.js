'use strict';

const fs = require('fs');
const path = require('path');
const { isValidProjectPort, parsePort } = require('./portUtils');
const { validateLocalProjectURL } = require('./urlValidation');
const { validateProjectDraft } = require('./projectValidation');
const { inspectProjectDirectory } = require('./projectInspection');

const MAX_TIMELINE_EVENTS = 25;
const MAX_REPORT_LOG_LINES = 20;
const DOCTOR_STATUSES = new Set([
  'idle',
  'checking',
  'starting',
  'waiting',
  'ready',
  'attention',
  'failed',
  'stopped',
]);
const CHECK_STATUSES = new Set(['pending', 'running', 'pass', 'warn', 'fail']);
const CHECK_DEFINITIONS = [
  ['directory', 'Directory'],
  ['command', 'Command'],
  ['dependencies', 'Dependencies'],
  ['port', 'Port'],
  ['url', 'URL'],
  ['process', 'Process'],
  ['readiness', 'Readiness'],
];
const ACTIONS = {
  USE_FREE_PORT: 'use-free-port',
  SYNC_URL_TO_PORT: 'sync-url-to-port',
  REVEAL_DIRECTORY: 'reveal-directory',
  COPY_REPORT: 'copy-report',
  REVEAL_COMMAND: 'reveal-command',
};
const ACTION_LABELS = {
  [ACTIONS.USE_FREE_PORT]: 'Find Free Port',
  [ACTIONS.SYNC_URL_TO_PORT]: 'Sync URL',
  [ACTIONS.REVEAL_DIRECTORY]: 'Reveal Folder',
  [ACTIONS.COPY_REPORT]: 'Copy Report',
  [ACTIONS.REVEAL_COMMAND]: 'Reveal Command',
};
const MUTATING_ACTIONS = new Set([ACTIONS.USE_FREE_PORT, ACTIONS.SYNC_URL_TO_PORT]);
const SAFE_ACTION_IDS = new Set(Object.values(ACTIONS));

function nowIso() {
  return new Date().toISOString();
}

function createAction(id) {
  if (!SAFE_ACTION_IDS.has(id)) {
    throw new Error(`Unknown Project Doctor action: ${id}`);
  }

  return {
    id,
    label: ACTION_LABELS[id],
    mutatesProject: MUTATING_ACTIONS.has(id),
  };
}

function createCheck(id, label) {
  return {
    id,
    label,
    status: 'pending',
    message: 'Not checked yet.',
    actions: [],
  };
}

function normalizeStatus(status, allowed, fallback) {
  return allowed.has(status) ? status : fallback;
}

function createDiagnosis(status = 'idle', options = {}) {
  const at = options.now ? options.now() : nowIso();
  return {
    status: normalizeStatus(status, DOCTOR_STATUSES, 'idle'),
    summary: 'Project Doctor has not checked this project yet.',
    updatedAt: at,
    checks: CHECK_DEFINITIONS.map(([id, label]) => createCheck(id, label)),
    timeline: [],
    actions: [],
  };
}

function cloneDiagnosis(diagnosis) {
  return JSON.parse(JSON.stringify(diagnosis || createDiagnosis()));
}

function findCheck(diagnosis, checkId) {
  return diagnosis.checks.find((check) => check.id === checkId);
}

function refreshActions(diagnosis) {
  const seen = new Set();
  const actions = [];
  diagnosis.checks.forEach((check) => {
    check.actions.forEach((action) => {
      if (!seen.has(action.id)) {
        seen.add(action.id);
        actions.push(action);
      }
    });
  });
  diagnosis.actions = actions;
}

function setCheck(diagnosis, checkId, status, message, actionIds = []) {
  const check = findCheck(diagnosis, checkId);
  if (!check) {
    throw new Error(`Unknown Project Doctor check: ${checkId}`);
  }

  check.status = normalizeStatus(status, CHECK_STATUSES, 'pending');
  check.message = message;
  check.actions = actionIds.map(createAction);
  refreshActions(diagnosis);
  return diagnosis;
}

function addTimelineEvent(diagnosis, message, status = 'info', options = {}) {
  const at = options.now ? options.now() : nowIso();
  diagnosis.timeline.push({
    at,
    status,
    message,
  });
  diagnosis.timeline = diagnosis.timeline.slice(-MAX_TIMELINE_EVENTS);
  diagnosis.updatedAt = at;
  return diagnosis;
}

function finalizeDiagnosis(diagnosis, summary, status, options = {}) {
  const at = options.now ? options.now() : nowIso();
  diagnosis.summary = summary;
  diagnosis.status = normalizeStatus(status, DOCTOR_STATUSES, 'idle');
  diagnosis.updatedAt = at;
  refreshActions(diagnosis);
  return diagnosis;
}

function findMessage(messages, field) {
  return messages.find((message) => message.field === field);
}

function directoryExists(cwd, fsImpl = fs) {
  return Boolean(cwd && fsImpl.existsSync(cwd) && fsImpl.statSync(cwd).isDirectory());
}

function readPackageJson(cwd, fsImpl = fs) {
  if (!directoryExists(cwd, fsImpl)) {
    return null;
  }

  const packagePath = path.join(cwd, 'package.json');
  if (!fsImpl.existsSync(packagePath)) {
    return null;
  }

  try {
    return JSON.parse(fsImpl.readFileSync(packagePath, 'utf8'));
  } catch (_error) {
    return null;
  }
}

function hasDependencies(packageJson) {
  return Boolean(
    packageJson &&
    ((packageJson.dependencies && Object.keys(packageJson.dependencies).length > 0) ||
      (packageJson.devDependencies && Object.keys(packageJson.devDependencies).length > 0))
  );
}

function inferInstallCommand(cwd, fsImpl = fs) {
  if (fsImpl.existsSync(path.join(cwd, 'pnpm-lock.yaml'))) {
    return 'pnpm install';
  }
  if (fsImpl.existsSync(path.join(cwd, 'yarn.lock'))) {
    return 'yarn install';
  }
  if (
    fsImpl.existsSync(path.join(cwd, 'bun.lock')) ||
    fsImpl.existsSync(path.join(cwd, 'bun.lockb'))
  ) {
    return 'bun install';
  }
  if (fsImpl.existsSync(path.join(cwd, 'package-lock.json'))) {
    return 'npm install';
  }
  return 'npm install';
}

function getDependencyWarning(cwd, fsImpl = fs) {
  const packageJson = readPackageJson(cwd, fsImpl);
  if (!hasDependencies(packageJson)) {
    return null;
  }

  const modulesPath = path.join(cwd, 'node_modules');
  if (fsImpl.existsSync(modulesPath) && fsImpl.statSync(modulesPath).isDirectory()) {
    return null;
  }

  const installCommand = inferInstallCommand(cwd, fsImpl);
  return {
    field: 'dependencies',
    code: 'node-modules-missing',
    message: `Dependencies may be missing. Next: run ${installCommand} in this folder if start fails.`,
    installCommand,
  };
}

function getUrlPort(url) {
  try {
    return parsePort(new URL(url).port);
  } catch (_error) {
    return NaN;
  }
}

function isLocalUrlOnPort(url, port) {
  return validateLocalProjectURL(url) && getUrlPort(url) === parsePort(port);
}

function shouldSyncUrlForPort(project, nextPort) {
  return !project.url || isLocalUrlOnPort(project.url, project.port || nextPort);
}

function mapFieldCheck(diagnosis, checkId, validation, field, passMessage, warningActions = []) {
  const error = findMessage(validation.errors, field);
  const warning = findMessage(validation.warnings, field);

  if (error) {
    setCheck(diagnosis, checkId, 'fail', error.message);
    return;
  }

  if (warning) {
    setCheck(diagnosis, checkId, 'warn', warning.message, warningActions);
    return;
  }

  setCheck(diagnosis, checkId, 'pass', passMessage);
}

async function diagnoseProjectDraft(draft = {}, options = {}) {
  const fsImpl = options.fsImpl || fs;
  const now = options.now || nowIso;
  const validation = await (options.validateProjectDraft || validateProjectDraft)(draft, {
    fsImpl,
    checkPortAvailable: options.checkPortAvailable,
    checkAvailability: options.checkAvailability,
  });
  const inspection = await (options.inspectProjectDirectory || inspectProjectDirectory)(
    validation.normalized.cwd,
    {
      fsImpl,
      findAvailablePort: options.findAvailablePort,
    }
  );
  const dependencyWarning = getDependencyWarning(validation.normalized.cwd, fsImpl);
  const diagnosis = createDiagnosis('checking', { now });

  addTimelineEvent(diagnosis, 'Checked project configuration.', 'info', { now });

  const cwdWarning = inspection.warnings.find((warning) => warning.field === 'cwd');
  if (findMessage(validation.errors, 'cwd')) {
    mapFieldCheck(diagnosis, 'directory', validation, 'cwd', 'Directory exists.');
  } else if (cwdWarning) {
    setCheck(diagnosis, 'directory', 'warn', cwdWarning.message);
  } else {
    setCheck(diagnosis, 'directory', 'pass', 'Directory exists.', [ACTIONS.REVEAL_DIRECTORY]);
  }

  const commandWarning = inspection.warnings.find((warning) => warning.field === 'command');
  if (findMessage(validation.errors, 'command')) {
    mapFieldCheck(diagnosis, 'command', validation, 'command', 'Command is allowed.');
  } else if (commandWarning) {
    setCheck(diagnosis, 'command', 'warn', commandWarning.message, [ACTIONS.REVEAL_COMMAND]);
  } else {
    setCheck(diagnosis, 'command', 'pass', 'Command is allowed.', [ACTIONS.REVEAL_COMMAND]);
  }

  if (dependencyWarning) {
    setCheck(diagnosis, 'dependencies', 'warn', dependencyWarning.message);
  } else if (directoryExists(validation.normalized.cwd, fsImpl)) {
    setCheck(diagnosis, 'dependencies', 'pass', 'No dependency warning detected.');
  } else {
    setCheck(diagnosis, 'dependencies', 'pending', 'Choose an existing directory first.');
  }

  mapFieldCheck(diagnosis, 'port', validation, 'port', 'Port is valid.', [ACTIONS.USE_FREE_PORT]);
  mapFieldCheck(diagnosis, 'url', validation, 'url', 'URL is local.', [ACTIONS.SYNC_URL_TO_PORT]);
  setCheck(diagnosis, 'process', 'pending', 'Process has not started yet.');
  setCheck(diagnosis, 'readiness', 'pending', 'Readiness check has not started yet.');

  if (validation.errors.length > 0) {
    addTimelineEvent(diagnosis, 'Preflight found errors that block start.', 'fail', { now });
    return {
      ...finalizeDiagnosis(
        diagnosis,
        'Start is blocked. Next: fix the failed Doctor check.',
        'failed',
        { now }
      ),
      validation,
    };
  }

  const warningCount = validation.warnings.length + (dependencyWarning ? 1 : 0);
  if (warningCount > 0) {
    addTimelineEvent(diagnosis, 'Preflight found warnings.', 'warn', { now });
    return {
      ...finalizeDiagnosis(
        diagnosis,
        'Project can start, but Doctor found warnings. Next: review the highlighted checks.',
        'attention',
        {
          now,
        }
      ),
      validation,
    };
  }

  addTimelineEvent(diagnosis, 'Preflight checks passed.', 'pass', { now });
  return {
    ...finalizeDiagnosis(diagnosis, 'Project looks ready to start. Next: Save & Start.', 'idle', {
      now,
    }),
    validation,
  };
}

function updateRuntimeDiagnosis(diagnosis, update = {}, options = {}) {
  const next = cloneDiagnosis(diagnosis);
  const now = options.now || nowIso;

  if (update.status) {
    next.status = normalizeStatus(update.status, DOCTOR_STATUSES, next.status);
  }

  if (update.summary) {
    next.summary = update.summary;
  }

  if (update.check) {
    setCheck(
      next,
      update.check.id,
      update.check.status,
      update.check.message,
      update.check.actions || []
    );
  }

  if (update.timeline) {
    addTimelineEvent(next, update.timeline.message, update.timeline.status, { now });
  }

  next.updatedAt = now();
  return next;
}

function getDoctorActionPatch(project, actionId, options = {}) {
  if (!SAFE_ACTION_IDS.has(actionId)) {
    throw new Error(`Unknown Project Doctor action: ${actionId}`);
  }

  if (actionId === ACTIONS.SYNC_URL_TO_PORT) {
    return {
      url: `http://localhost:${project.port}`,
    };
  }

  if (actionId === ACTIONS.USE_FREE_PORT) {
    const nextPort = options.port;
    if (!isValidProjectPort(nextPort)) {
      throw new Error('Project Doctor requires a valid available port.');
    }

    const patch = { port: parsePort(nextPort) };
    if (shouldSyncUrlForPort(project, nextPort)) {
      patch.url = `http://localhost:${nextPort}`;
    }
    return patch;
  }

  return {};
}

function formatCheck(check) {
  return `${check.label}: ${check.status} - ${check.message}`;
}

function formatTimelineEvent(event) {
  return `${event.at} ${event.message}`;
}

function buildDoctorReport(project, runtime = {}) {
  const diagnosis = runtime.diagnosis || createDiagnosis();
  const lines = [
    `LocalWrap Doctor Report`,
    `Project: ${project.name || 'Untitled Project'}`,
    `Directory: ${project.cwd || '-'}`,
    `Command: ${project.command || '-'}`,
    `Port: ${project.port || '-'}`,
    `URL: ${project.url || '-'}`,
    `Runtime Status: ${runtime.status || 'stopped'}`,
    `Doctor Status: ${diagnosis.status}`,
    `Summary: ${diagnosis.summary}`,
    `Exit Code: ${runtime.lastExitCode ?? runtime.exitCode ?? '-'}`,
    `Readiness: ${runtime.readinessMessage || '-'}`,
    '',
    'Checks:',
    ...diagnosis.checks.map(formatCheck),
    '',
    'Timeline:',
    ...(diagnosis.timeline.length > 0
      ? diagnosis.timeline.map(formatTimelineEvent)
      : ['No timeline events.']),
    '',
    'Recent Logs:',
    ...((runtime.logs || []).slice(-MAX_REPORT_LOG_LINES).length > 0
      ? (runtime.logs || []).slice(-MAX_REPORT_LOG_LINES)
      : ['No logs.']),
  ];

  return `${lines.join('\n')}\n`;
}

module.exports = {
  ACTIONS,
  CHECK_DEFINITIONS,
  CHECK_STATUSES,
  DOCTOR_STATUSES,
  MAX_TIMELINE_EVENTS,
  SAFE_ACTION_IDS,
  addTimelineEvent,
  buildDoctorReport,
  createAction,
  createDiagnosis,
  diagnoseProjectDraft,
  getDependencyWarning,
  getDoctorActionPatch,
  getUrlPort,
  inferInstallCommand,
  updateRuntimeDiagnosis,
};
