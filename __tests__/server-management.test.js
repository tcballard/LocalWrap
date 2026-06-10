const { EventEmitter } = require('events');
const { ProjectLifecycle, killProcessTree } = require('../lib/projectLifecycle');
const { waitForReady } = require('../lib/readiness');

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
      child.emit('close', 0);
      return true;
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

  test('stop aborts the readiness polling immediately', async () => {
    const probe = jest.fn().mockResolvedValue(false);
    const child = createFakeChild();
    const lifecycle = new ProjectLifecycle({
      startScript: jest.fn(() => child),
      waitForReady: (url, options) =>
        waitForReady(url, { ...options, timeoutMs: 1000, intervalMs: 5, probe }),
      killProcessTree: jest.fn(async () => {
        child.emit('close', 0);
        return true;
      }),
    });

    await lifecycle.start(createProject());
    await new Promise((resolve) => setTimeout(resolve, 25)); // let polling run
    await lifecycle.stop('project-1');

    const probesAtStop = probe.mock.calls.length;
    expect(probesAtStop).toBeGreaterThan(0);
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(probe.mock.calls.length).toBe(probesAtStop);
    expect(lifecycle.getState('project-1').status).toBe('stopped');
  });

  test('ignores output and exit from a previous run after a restart', async () => {
    let firstOnLine;
    let firstOnExit;
    const startScript = jest
      .fn()
      .mockImplementationOnce((options) => {
        firstOnLine = options.onLine;
        firstOnExit = options.onExit;
        return createFakeChild(111);
      })
      .mockImplementationOnce(() => createFakeChild(222));
    const lifecycle = new ProjectLifecycle({
      startScript,
      waitForReady: jest.fn(() => new Promise(() => {})),
      killProcessTree: jest.fn(async () => true),
    });

    await lifecycle.start(createProject());
    await lifecycle.restart(createProject());

    // The old process dies late, after the new run has already started.
    firstOnLine('zombie output');
    firstOnExit(137);

    const state = lifecycle.getState('project-1');
    expect(state.status).toBe('starting');
    expect(state.pid).toBe(222);
    expect(state.logs).not.toContain('zombie output');
    expect(state.logs.join('\n')).not.toMatch(/exited with code 137/);
    expect(state.lastExitCode).toBeNull();
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

// Stop must be truthful: a process that survives the kill escalation is
// reported running-unresponsive (still holding its port), never "stopped".
describe('stop with a SIGTERM-ignoring process', () => {
  const testOnPosix = process.platform === 'win32' ? test.skip : test;

  test('reports running-unresponsive when the process never exits', async () => {
    const child = new EventEmitter();
    child.pid = 4321;
    child.kill = jest.fn(() => true);
    const ignoredKill = jest.fn(async () => false); // delivery attempted, no exit observed
    const lifecycle = new ProjectLifecycle({
      startScript: jest.fn(() => child),
      waitForReady: jest.fn(() => new Promise(() => {})),
      killProcessTree: ignoredKill,
    });

    await lifecycle.start(createProject());
    const state = await lifecycle.stop('project-1');

    expect(ignoredKill).toHaveBeenCalledWith(child);
    expect(state.status).toBe('running-unresponsive');
    expect(state.pid).toBe(4321);
    expect(state.readinessMessage).toMatch(/did not exit/);
    expect(state.diagnosis).toMatchObject({
      status: 'attention',
      summary: 'Stop requested, but the process did not exit.',
    });
    // The survivor stays active so Stop can be retried and edits stay locked.
    expect(lifecycle.isActive('project-1')).toBe(true);
  });

  testOnPosix('escalates to SIGKILL when SIGTERM is ignored', async () => {
    const child = new EventEmitter();
    child.pid = 4242;
    child.kill = jest.fn(() => true);
    const killSpy = jest.spyOn(process, 'kill').mockImplementation(() => true);
    try {
      const exited = await killProcessTree(child, { termGraceMs: 10, killGraceMs: 10 });

      expect(exited).toBe(false);
      expect(killSpy.mock.calls).toEqual([
        [-4242, 'SIGTERM'],
        [-4242, 'SIGKILL'],
      ]);
    } finally {
      killSpy.mockRestore();
    }
  });

  testOnPosix('does not escalate when SIGTERM is honored', async () => {
    const child = new EventEmitter();
    child.pid = 4242;
    child.kill = jest.fn(() => true);
    const killSpy = jest.spyOn(process, 'kill').mockImplementation((_pid, signal) => {
      if (signal === 'SIGTERM') {
        setImmediate(() => child.emit('close', 0));
      }
      return true;
    });
    try {
      const exited = await killProcessTree(child, { termGraceMs: 1000, killGraceMs: 10 });

      expect(exited).toBe(true);
      expect(killSpy.mock.calls).toEqual([[-4242, 'SIGTERM']]);
    } finally {
      killSpy.mockRestore();
    }
  });
});
