'use strict';

const { EventEmitter } = require('events');
const { startScript } = require('./scriptRunner');
const { waitForReady } = require('./readiness');
const { diagnoseProjectDraft, updateRuntimeDiagnosis } = require('./projectDoctor');

// Shared with the renderer via public/shared-constants.js so both sides of
// the IPC bridge agree on what counts as an active project.
const { ACTIVE_STATUSES: ACTIVE_STATUS_LIST } = require('../public/shared-constants');

const MAX_LOG_LINES = 500;
const ACTIVE_STATUSES = new Set(ACTIVE_STATUS_LIST);

function clone(value) {
  return value ? JSON.parse(JSON.stringify(value)) : null;
}

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
      diagnosis: null,
      diagnosisTimeline: [],
      lastDiagnosisAt: null,
    };
  }

  const diagnosis = clone(state.diagnosis);

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
    diagnosis,
    diagnosisTimeline: diagnosis?.timeline || [],
    lastDiagnosisAt: diagnosis?.updatedAt || null,
    logs: state.logs.slice(-MAX_LOG_LINES),
  };
}

/**
 * Wait for the child to exit, up to timeoutMs. Resolves true when an
 * exit/close event was observed, false when the wait timed out.
 */
function waitForChildExit(child, timeoutMs = 5000) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (exited) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(exited);
    };
    const onEvent = () => finish(true);
    const timer = setTimeout(() => finish(false), timeoutMs);
    child.once('close', onEvent);
    child.once('exit', onEvent);
  });
}

function signalProcessTree(child, signal) {
  try {
    process.kill(-child.pid, signal);
  } catch (_error) {
    try {
      child.kill(signal);
    } catch (__error) {
      // Process is likely already gone; the exit wait decides the outcome.
    }
  }
}

/**
 * Terminate a project's process tree and report whether it actually exited.
 *
 * POSIX: SIGTERM to the process group, escalating to SIGKILL if the process
 * is still alive after the grace period. Windows: taskkill /T /F is already
 * forceful. Resolves true only when an exit/close event was observed, so
 * callers can report a process that survived instead of claiming it stopped.
 */
async function killProcessTree(child, options = {}) {
  if (!child || !child.pid) {
    return true;
  }

  const termGraceMs = options.termGraceMs ?? 5000;
  const killGraceMs = options.killGraceMs ?? 2000;

  if (process.platform === 'win32') {
    const { spawn } = require('child_process');
    await new Promise((resolve) => {
      const killer = spawn('taskkill', ['/pid', String(child.pid), '/T', '/F']);
      killer.on('close', resolve);
      killer.on('error', resolve);
    });
    return waitForChildExit(child, termGraceMs);
  }

  signalProcessTree(child, 'SIGTERM');
  if (await waitForChildExit(child, termGraceMs)) {
    return true;
  }

  signalProcessTree(child, 'SIGKILL');
  return waitForChildExit(child, killGraceMs);
}

class ProjectLifecycle extends EventEmitter {
  constructor(options = {}) {
    super();
    this.startScript = options.startScript || startScript;
    this.waitForReady = options.waitForReady || waitForReady;
    this.killProcessTree = options.killProcessTree || killProcessTree;
    this.now = options.now || (() => new Date().toISOString());
    this.openProject = options.openProject || (() => {});
    this.diagnoseProjectDraft =
      options.diagnoseProjectDraft ||
      ((project) =>
        diagnoseProjectDraft(project, {
          checkPortAvailable: options.checkPortAvailable,
          findAvailablePort: options.findAvailablePort,
          now: this.now,
        }));
    this.states = new Map();
    this.runCounter = 0;
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

  getActiveProjectIds() {
    return Array.from(this.states.keys()).filter((projectId) => this.isActive(projectId));
  }

  async start(project) {
    if (this.isActive(project.id)) {
      throw new Error('Project is already running.');
    }

    const runId = ++this.runCounter;
    const state = {
      projectId: project.id,
      runId,
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
      diagnosis: updateRuntimeDiagnosis(
        null,
        {
          status: 'checking',
          summary: 'Checking project before start. Next: wait for Doctor preflight.',
          timeline: {
            status: 'info',
            message: 'Checking project before start.',
          },
        },
        { now: this.now }
      ),
      abort: new AbortController(),
    };

    this.states.set(project.id, state);
    this.emitState(project.id);

    const isCurrentRun = () => this.states.get(project.id)?.runId === runId;

    const onLine = (line) => {
      // A previous run's process can keep emitting briefly after a restart.
      if (!isCurrentRun()) return;
      this.appendLog(project.id, line);
    };

    const onExit = (code) => {
      // A previous run's late exit must not touch the new run's state.
      if (!isCurrentRun()) return;
      const failed = code !== 0;
      state.status = 'stopped';
      state.child = null;
      state.pid = null;
      state.stoppedAt = this.now();
      state.lastStoppedAt = state.stoppedAt;
      state.exitCode = code;
      state.lastExitCode = code;
      state.readinessMessage =
        code === 0 ? 'Process stopped.' : `Process exited with code ${code}.`;
      state.abort.abort();
      state.diagnosis = updateRuntimeDiagnosis(
        state.diagnosis,
        {
          status: failed ? 'failed' : 'stopped',
          summary: failed
            ? `Process exited with code ${code}. Next: review the output log.`
            : 'Project stopped.',
          check: {
            id: 'process',
            status: failed ? 'fail' : 'pass',
            message: failed ? `Process exited with code ${code}.` : 'Process stopped.',
          },
          timeline: {
            status: failed ? 'fail' : 'info',
            message: failed ? `Process exited with code ${code}.` : 'Process stopped.',
          },
        },
        { now: this.now }
      );
      this.appendLog(project.id, `[process exited with code ${code}]`);
      this.emitState(project.id);
    };

    try {
      const preflight = await this.diagnoseProjectDraft(project);
      state.diagnosis = preflight;
      this.emitState(project.id);

      if (preflight.validation?.errors?.length > 0) {
        const error = new Error('Fix Doctor errors before starting.');
        error.doctorBlocked = true;
        state.status = 'failed';
        state.error = error.message;
        state.readinessMessage = error.message;
        state.abort.abort();
        this.appendLog(project.id, `[doctor] ${error.message}`);
        this.emitState(project.id);
        throw error;
      }

      state.diagnosis = updateRuntimeDiagnosis(
        state.diagnosis,
        {
          status: 'starting',
          summary: 'Starting project command. Next: wait for the process to launch.',
          check: {
            id: 'process',
            status: 'running',
            message: 'Starting command.',
          },
          timeline: {
            status: 'info',
            message: `Starting command: ${project.command}`,
          },
        },
        { now: this.now }
      );
      this.emitState(project.id);

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
      state.diagnosis = updateRuntimeDiagnosis(
        state.diagnosis,
        {
          status: 'waiting',
          summary: 'Command started. Next: wait for the app URL to respond.',
          check: {
            id: 'process',
            status: 'pass',
            message: `Process started${child.pid ? ` (PID ${child.pid})` : ''}.`,
          },
          timeline: {
            status: 'pass',
            message: 'Process started.',
          },
        },
        { now: this.now }
      );
      state.diagnosis = updateRuntimeDiagnosis(
        state.diagnosis,
        {
          status: 'waiting',
          check: {
            id: 'readiness',
            status: 'running',
            message: `Waiting for ${project.url}.`,
          },
          timeline: {
            status: 'info',
            message: `Waiting for ${project.url}.`,
          },
        },
        { now: this.now }
      );
      this.emitState(project.id);
      this.watchReadiness(project, state);
      return summarizeState(state);
    } catch (error) {
      if (error.doctorBlocked) {
        throw error;
      }

      state.status = 'failed';
      state.error = error.message;
      state.readinessMessage = 'Project failed to start.';
      state.abort.abort();
      state.diagnosis = updateRuntimeDiagnosis(
        state.diagnosis,
        {
          status: 'failed',
          summary: 'Project failed to start. Next: review the failed process check.',
          check: {
            id: 'process',
            status: 'fail',
            message: error.message,
          },
          timeline: {
            status: 'fail',
            message: `Process failed to start: ${error.message}`,
          },
        },
        { now: this.now }
      );
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
    state.abort.abort();
    state.diagnosis = updateRuntimeDiagnosis(
      state.diagnosis,
      {
        status: 'stopped',
        summary: 'Stopping project.',
        timeline: {
          status: 'info',
          message: 'Stopping project.',
        },
      },
      { now: this.now }
    );
    this.emitState(projectId);

    const exitObserved = await this.killProcessTree(state.child);

    // When the exit event already ran the onExit bookkeeping, child is null
    // and there is nothing left to record here.
    if (state.child) {
      if (exitObserved) {
        state.child = null;
        state.pid = null;
        state.status = 'stopped';
        state.stoppedAt = this.now();
        state.lastStoppedAt = state.stoppedAt;
        state.readinessMessage = 'Project stopped.';
        state.diagnosis = updateRuntimeDiagnosis(
          state.diagnosis,
          {
            status: 'stopped',
            summary: 'Project stopped.',
            check: {
              id: 'process',
              status: 'pass',
              message: 'Project stopped.',
            },
            timeline: {
              status: 'info',
              message: 'Project stopped.',
            },
          },
          { now: this.now }
        );
        this.emitState(projectId);
      } else {
        // The process survived SIGTERM and SIGKILL escalation (or its exit
        // was never observed). Saying "stopped" here would hide a live
        // process that may still hold the project's port.
        state.status = 'running-unresponsive';
        state.readinessMessage = 'Process did not exit after stop; it may still be running.';
        state.diagnosis = updateRuntimeDiagnosis(
          state.diagnosis,
          {
            status: 'attention',
            summary: 'Stop requested, but the process did not exit.',
            check: {
              id: 'process',
              status: 'warn',
              message: 'Process did not exit after stop; it may still hold the project port.',
            },
            timeline: {
              status: 'warn',
              message: 'Process did not exit after stop.',
            },
          },
          { now: this.now }
        );
        this.appendLog(projectId, '[stop] Process did not exit; it may still be running.');
        this.emitState(projectId);
      }
    }

    return summarizeState(state);
  }

  async restart(project) {
    await this.stop(project.id);
    return this.start(project);
  }

  async startAll(projects = []) {
    const results = [];
    for (const project of projects) {
      try {
        if (this.isActive(project.id)) {
          results.push({
            projectId: project.id,
            status: 'skipped',
            state: this.getState(project.id),
          });
          continue;
        }

        const state = await this.start(project);
        results.push({
          projectId: project.id,
          status: 'started',
          state,
        });
      } catch (error) {
        results.push({
          projectId: project.id,
          status: 'failed',
          error: error.message,
          state: this.getState(project.id),
        });
      }
    }
    return results;
  }

  async stopAll() {
    const ids = Array.from(this.states.keys());
    return Promise.all(ids.map((id) => this.stop(id)));
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
    const signal = state.abort.signal;
    try {
      // The signal stops the polling loop itself on stop/exit, not just the
      // handling of its result.
      const ready = await this.waitForReady(project.url, {
        timeoutMs: 30000,
        intervalMs: 500,
        signal,
      });

      if (signal.aborted || !state.child) {
        return;
      }

      if (ready) {
        state.status = 'ready';
        state.readyAt = this.now();
        state.readinessMessage = 'Project is ready.';
        state.diagnosis = updateRuntimeDiagnosis(
          state.diagnosis,
          {
            status: 'ready',
            summary: 'Project is ready. Next: preview or open it.',
            check: {
              id: 'readiness',
              status: 'pass',
              message: `${project.url} responded.`,
            },
            timeline: {
              status: 'pass',
              message: `${project.url} responded.`,
            },
          },
          { now: this.now }
        );
        this.appendLog(project.id, `[ready] ${project.url}`);
        this.emitState(project.id);

        if (project.openOnReady) {
          this.openProject(project);
        }
      } else {
        state.status = 'running-unresponsive';
        state.readinessMessage = `${project.url} did not respond before timeout.`;
        state.diagnosis = updateRuntimeDiagnosis(
          state.diagnosis,
          {
            status: 'attention',
            summary:
              'Project is running but the URL is not responding. Next: check the URL and port.',
            check: {
              id: 'readiness',
              status: 'warn',
              message: state.readinessMessage,
            },
            timeline: {
              status: 'warn',
              message: state.readinessMessage,
            },
          },
          { now: this.now }
        );
        this.appendLog(project.id, `[running-unresponsive] ${state.readinessMessage}`);
        this.emitState(project.id);
      }
    } catch (error) {
      if (!signal.aborted && state.child) {
        state.status = 'running-unresponsive';
        state.error = error.message;
        state.readinessMessage = error.message;
        state.diagnosis = updateRuntimeDiagnosis(
          state.diagnosis,
          {
            status: 'attention',
            summary: 'Readiness check could not complete. Next: review the readiness message.',
            check: {
              id: 'readiness',
              status: 'warn',
              message: error.message,
            },
            timeline: {
              status: 'warn',
              message: `Readiness check failed: ${error.message}`,
            },
          },
          { now: this.now }
        );
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
