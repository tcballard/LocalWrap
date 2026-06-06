'use strict';

const { EventEmitter } = require('events');
const { startScript } = require('./scriptRunner');
const { waitForReady } = require('./readiness');

const MAX_LOG_LINES = 500;
const ACTIVE_STATUSES = new Set(['starting', 'ready', 'running-unresponsive', 'stopping']);

function summarizeState(state) {
  if (!state) {
    return {
      status: 'stopped',
      pid: null,
      logs: [],
      lastExitCode: null,
      lastStartedAt: null,
      lastStoppedAt: null,
      readinessMessage: null,
    };
  }

  return {
    status: state.status,
    pid: state.pid || null,
    startedAt: state.startedAt || null,
    stoppedAt: state.stoppedAt || null,
    readyAt: state.readyAt || null,
    exitCode: state.exitCode,
    lastExitCode: state.lastExitCode,
    lastStartedAt: state.lastStartedAt || state.startedAt || null,
    lastStoppedAt: state.lastStoppedAt || state.stoppedAt || null,
    readinessMessage: state.readinessMessage || null,
    error: state.error || null,
    logs: state.logs.slice(-MAX_LOG_LINES),
  };
}

function waitForChildExit(child, timeoutMs = 5000) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(finish, timeoutMs);
    child.once('close', finish);
    child.once('exit', finish);
  });
}

function killProcessTree(child) {
  if (!child || !child.pid) {
    return Promise.resolve();
  }

  if (process.platform === 'win32') {
    const { spawn } = require('child_process');
    return new Promise((resolve) => {
      const killer = spawn('taskkill', ['/pid', String(child.pid), '/T', '/F']);
      killer.on('close', resolve);
      killer.on('error', resolve);
    });
  }

  try {
    process.kill(-child.pid, 'SIGTERM');
  } catch (_error) {
    try {
      child.kill('SIGTERM');
    } catch (__error) {
      return Promise.resolve();
    }
  }

  return Promise.resolve();
}

class ProjectLifecycle extends EventEmitter {
  constructor(options = {}) {
    super();
    this.startScript = options.startScript || startScript;
    this.waitForReady = options.waitForReady || waitForReady;
    this.killProcessTree = options.killProcessTree || killProcessTree;
    this.now = options.now || (() => new Date().toISOString());
    this.openProject = options.openProject || (() => {});
    this.states = new Map();
  }

  getState(projectId) {
    return summarizeState(this.states.get(projectId));
  }

  getStates() {
    const result = {};
    for (const [projectId, state] of this.states.entries()) {
      result[projectId] = summarizeState(state);
    }
    return result;
  }

  isActive(projectId) {
    const state = this.states.get(projectId);
    return Boolean(state?.child && ACTIVE_STATUSES.has(state.status));
  }

  async start(project) {
    if (this.isActive(project.id)) {
      throw new Error('Project is already running.');
    }

    const state = {
      projectId: project.id,
      status: 'starting',
      child: null,
      pid: null,
      logs: [],
      startedAt: this.now(),
      stoppedAt: null,
      readyAt: null,
      exitCode: null,
      lastExitCode: null,
      lastStartedAt: this.now(),
      lastStoppedAt: null,
      readinessMessage: 'Waiting for the local app to respond.',
      error: null,
      readinessToken: { cancelled: false },
    };

    this.states.set(project.id, state);
    this.emitState(project.id);

    const onLine = (line) => {
      this.appendLog(project.id, line);
    };

    const onExit = (code) => {
      state.status = 'stopped';
      state.child = null;
      state.pid = null;
      state.stoppedAt = this.now();
      state.lastStoppedAt = state.stoppedAt;
      state.exitCode = code;
      state.lastExitCode = code;
      state.readinessMessage =
        code === 0 ? 'Process stopped.' : `Process exited with code ${code}.`;
      state.readinessToken.cancelled = true;
      this.appendLog(project.id, `[process exited with code ${code}]`);
      this.emitState(project.id);
    };

    try {
      const child = this.startScript({
        command: project.command,
        cwd: project.cwd,
        port: project.port,
        onLine,
        onExit,
      });
      state.child = child;
      state.pid = child.pid;
      state.status = 'starting';
      state.lastStartedAt = state.startedAt;
      this.emitState(project.id);
      this.watchReadiness(project, state);
      return summarizeState(state);
    } catch (error) {
      state.status = 'failed';
      state.error = error.message;
      state.readinessMessage = 'Project failed to start.';
      state.readinessToken.cancelled = true;
      this.appendLog(project.id, `[error] ${error.message}`);
      this.emitState(project.id);
      throw error;
    }
  }

  async stop(projectId) {
    const state = this.states.get(projectId);
    if (!state?.child) {
      return summarizeState(state);
    }

    state.status = 'stopping';
    state.readinessToken.cancelled = true;
    this.emitState(projectId);

    const exited = waitForChildExit(state.child);
    await this.killProcessTree(state.child);
    await exited;

    if (state.child) {
      state.child = null;
      state.pid = null;
      state.status = 'stopped';
      state.stoppedAt = this.now();
      state.lastStoppedAt = state.stoppedAt;
      state.readinessMessage = 'Project stopped.';
      this.emitState(projectId);
    }

    return summarizeState(state);
  }

  async restart(project) {
    await this.stop(project.id);
    return this.start(project);
  }

  async stopAll() {
    const ids = Array.from(this.states.keys());
    await Promise.all(ids.map((id) => this.stop(id)));
  }

  appendLog(projectId, line) {
    const state = this.states.get(projectId);
    if (!state) return;

    state.logs.push(String(line));
    if (state.logs.length > MAX_LOG_LINES) {
      state.logs.shift();
    }

    this.emit('event', {
      type: 'output',
      projectId,
      line: String(line),
      state: summarizeState(state),
    });
  }

  clearLogs(projectId) {
    const state = this.states.get(projectId);
    if (!state) {
      return summarizeState(state);
    }

    state.logs = [];
    this.emit('event', {
      type: 'logs-cleared',
      projectId,
      state: summarizeState(state),
    });
    this.emitState(projectId);
    return summarizeState(state);
  }

  emitState(projectId) {
    this.emit('event', {
      type: 'state',
      projectId,
      state: this.getState(projectId),
    });
  }

  async watchReadiness(project, state) {
    const token = state.readinessToken;
    try {
      const ready = await this.waitForReady(project.url, {
        timeoutMs: 30000,
        intervalMs: 500,
      });

      if (token.cancelled || !state.child) {
        return;
      }

      if (ready) {
        state.status = 'ready';
        state.readyAt = this.now();
        state.readinessMessage = 'Project is ready.';
        this.appendLog(project.id, `[ready] ${project.url}`);
        this.emitState(project.id);

        if (project.openOnReady) {
          this.openProject(project);
        }
      } else {
        state.status = 'running-unresponsive';
        state.readinessMessage = `${project.url} did not respond before timeout.`;
        this.appendLog(project.id, `[running-unresponsive] ${state.readinessMessage}`);
        this.emitState(project.id);
      }
    } catch (error) {
      if (!token.cancelled && state.child) {
        state.status = 'running-unresponsive';
        state.error = error.message;
        state.readinessMessage = error.message;
        this.emitState(project.id);
      }
    }
  }
}

module.exports = {
  ACTIVE_STATUSES,
  MAX_LOG_LINES,
  ProjectLifecycle,
  killProcessTree,
  summarizeState,
  waitForChildExit,
};
