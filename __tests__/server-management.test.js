const { EventEmitter } = require('events');
const { ProjectLifecycle } = require('../lib/projectLifecycle');

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
    expect(state.logs).toContain('compiled');
    expect(state.logs).toContain('[ready] http://localhost:3000');
    expect(events.some((event) => event.type === 'output')).toBe(true);
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
