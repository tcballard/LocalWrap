const { EventEmitter } = require('events');
const { ProjectLifecycle, killProcessTree } = require('../lib/projectLifecycle');

function createFakeChild(pid = 1234) {
  const child = new EventEmitter();
  child.pid = pid;
  child.kill = jest.fn(() => {
    setImmediate(() => child.emit('close', 0));
    return true;
  });
  return child;
}

function createProject(overrides = {}) {
  return {
    id: 'project-1',
    name: 'Demo',
    cwd: __dirname,
    command: 'node --version',
    port: 3000,
    url: 'http://localhost:3000',
    openOnReady: false,
    ...overrides,
  };
}

describe('ProjectLifecycle', () => {
  test('starts a project, records output, and marks it ready', async () => {
    const events = [];
    let onLine;
    const lifecycle = new ProjectLifecycle({
      startScript: jest.fn((options) => {
        onLine = options.onLine;
        return createFakeChild();
      }),
      waitForReady: jest.fn(() => Promise.resolve(true)),
      now: () => '2026-06-05T00:00:00.000Z',
    });
    lifecycle.on('event', (event) => events.push(event));

    await lifecycle.start(createProject());
    onLine('compiled');
    await new Promise((resolve) => setImmediate(resolve));

    const state = lifecycle.getState('project-1');
    expect(state.status).toBe('ready');
    expect(state.pid).toBe(1234);
    expect(state.readinessMessage).toBe('Project is ready.');
    expect(state.diagnosis).toMatchObject({
      status: 'ready',
      summary: 'Project is ready.',
    });
    expect(state.diagnosisTimeline.map((event) => event.message)).toContain(
      'http://localhost:3000 responded.'
    );
    expect(state.logs).toContain('compiled');
    expect(state.logs).toContain('[ready] http://localhost:3000');
    expect(events.some((event) => event.type === 'output')).toBe(true);
  });

  test('marks a running project as unresponsive when readiness times out', async () => {
    const lifecycle = new ProjectLifecycle({
      startScript: jest.fn(() => createFakeChild()),
      waitForReady: jest.fn(() => Promise.resolve(false)),
    });

    await lifecycle.start(createProject());
    await new Promise((resolve) => setImmediate(resolve));

    const state = lifecycle.getState('project-1');
    expect(state.status).toBe('running-unresponsive');
    expect(state.readinessMessage).toMatch(/did not respond/);
    expect(state.diagnosis).toMatchObject({
      status: 'attention',
      summary: 'Project is running but the URL is not responding.',
    });
    expect(state.logs.join('\n')).toMatch(/running-unresponsive/);
  });

  test('marks spawn failures as failed', async () => {
    const lifecycle = new ProjectLifecycle({
      startScript: jest.fn(() => {
        throw new Error('spawn failed');
      }),
    });

    await expect(lifecycle.start(createProject())).rejects.toThrow(/spawn failed/);
    expect(lifecycle.getState('project-1')).toMatchObject({
      status: 'failed',
      error: 'spawn failed',
      readinessMessage: 'Project failed to start.',
      diagnosis: {
        status: 'failed',
        summary: 'Project failed to start.',
      },
    });
  });

  test('preserves exit metadata and clears logs', async () => {
    let onExit;
    const lifecycle = new ProjectLifecycle({
      startScript: jest.fn((options) => {
        onExit = options.onExit;
        return createFakeChild();
      }),
      waitForReady: jest.fn(() => new Promise(() => {})),
      now: () => '2026-06-06T00:00:00.000Z',
    });

    await lifecycle.start(createProject());
    lifecycle.appendLog('project-1', 'hello');
    onExit(1);

    expect(lifecycle.getState('project-1')).toMatchObject({
      status: 'stopped',
      lastExitCode: 1,
      lastStoppedAt: '2026-06-06T00:00:00.000Z',
      diagnosis: {
        status: 'failed',
        summary: 'Process exited with code 1.',
      },
    });

    lifecycle.clearLogs('project-1');
    expect(lifecycle.getState('project-1').logs).toEqual([]);
  });

  test('stops a running project by killing the process tree', async () => {
    const child = createFakeChild();
    const killProcessTree = jest.fn(async () => {
      setImmediate(() => child.emit('close', 0));
    });
    const lifecycle = new ProjectLifecycle({
      startScript: jest.fn(() => child),
      waitForReady: jest.fn(() => new Promise(() => {})),
      killProcessTree,
    });

    await lifecycle.start(createProject());
    await lifecycle.stop('project-1');

    expect(killProcessTree).toHaveBeenCalledWith(child);
    expect(lifecycle.getState('project-1').status).toBe('stopped');
  });

  test('opens a project automatically when readiness succeeds', async () => {
    const openProject = jest.fn();
    const lifecycle = new ProjectLifecycle({
      startScript: jest.fn(() => createFakeChild()),
      waitForReady: jest.fn(() => Promise.resolve(true)),
      openProject,
    });

    const project = createProject({ openOnReady: true });
    await lifecycle.start(project);
    await new Promise((resolve) => setImmediate(resolve));

    expect(openProject).toHaveBeenCalledWith(project);
  });
});

// These tests pin the CURRENT stop behavior for processes that ignore
// SIGTERM, so the kill-escalation fix can flip them deliberately. Today the
// state claims "stopped" after a 5s grace period even if the process never
// exited and is still holding its port.
describe('stop with a SIGTERM-ignoring process (pins current behavior)', () => {
  const testOnPosix = process.platform === 'win32' ? test.skip : test;

  afterEach(() => {
    jest.useRealTimers();
  });

  test('reports stopped after the grace period even though the process never exited', async () => {
    const child = new EventEmitter();
    child.pid = 4321;
    child.kill = jest.fn(() => true); // signal delivered, process ignores it
    const ignoredKill = jest.fn(async () => {});
    const lifecycle = new ProjectLifecycle({
      startScript: jest.fn(() => child),
      waitForReady: jest.fn(() => new Promise(() => {})),
      killProcessTree: ignoredKill,
    });

    await lifecycle.start(createProject());

    jest.useFakeTimers();
    const stopPromise = lifecycle.stop('project-1');
    await Promise.resolve(); // let stop() reach the exit wait
    jest.advanceTimersByTime(5000); // waitForChildExit gives up
    await stopPromise;

    expect(ignoredKill).toHaveBeenCalledWith(child);
    // KNOWN GAP (audit C2, fixed by M1.2): the child never emitted exit or
    // close, so the OS process is still alive, but the runtime claims it is
    // stopped. The fix should report 'running-unresponsive' here instead.
    const state = lifecycle.getState('project-1');
    expect(state.status).toBe('stopped');
    expect(state.pid).toBeNull();
  });

  testOnPosix('default killProcessTree sends a single SIGTERM and never escalates', async () => {
    const killSpy = jest.spyOn(process, 'kill').mockImplementation(() => true);
    try {
      await killProcessTree({ pid: 4242, kill: jest.fn() });

      // KNOWN GAP (audit C2, fixed by M1.2): one SIGTERM to the process
      // group is the only delivery attempt; no SIGKILL escalation exists.
      expect(killSpy).toHaveBeenCalledTimes(1);
      expect(killSpy).toHaveBeenCalledWith(-4242, 'SIGTERM');
    } finally {
      killSpy.mockRestore();
    }
  });
});
