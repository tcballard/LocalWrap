require('../public/app.js');

const renderer = global.LocalWrapRenderer;

describe('renderer view-model helpers', () => {
  test('creates a default unsaved project draft', () => {
    expect(renderer.createDefaultDraft({ suggestedPort: 5173 })).toMatchObject({
      isDraft: true,
      command: 'npm run dev',
      port: 5173,
      url: 'http://localhost:5173',
      openOnReady: true,
    });
  });

  test('normalizes missing runtime state', () => {
    expect(renderer.normalizeProjectForView({ id: 'a', name: 'App' }).runtime).toMatchObject({
      status: 'stopped',
      pid: null,
      logs: [],
      readinessMessage: null,
      diagnosis: null,
    });
  });

  test('merges project lifecycle events into the selected project', () => {
    const projects = [
      renderer.normalizeProjectForView({ id: 'a', name: 'A' }),
      renderer.normalizeProjectForView({ id: 'b', name: 'B' }),
    ];

    const next = renderer.mergeProjectEvent(projects, {
      projectId: 'b',
      state: { status: 'ready', pid: 42, logs: ['ready'] },
    });

    expect(next[0].runtime.status).toBe('stopped');
    expect(next[1].runtime.status).toBe('ready');
    expect(renderer.isProjectActive(next[1])).toBe(true);
  });

  test('labels current runtime states clearly', () => {
    expect(renderer.statusLabel('running-unresponsive')).toBe('Running, no response');
    expect(renderer.statusLabel('failed')).toBe('Failed');
    expect(renderer.isProjectActive({ runtime: { status: 'running' } })).toBe(true);
    expect(renderer.isProjectActive({ runtime: { status: 'running-unresponsive' } })).toBe(true);
  });

  test('preserves runtime diagnosis in project events', () => {
    const next = renderer.mergeProjectEvent(
      [renderer.normalizeProjectForView({ id: 'a', name: 'A' })],
      {
        projectId: 'a',
        state: {
          status: 'starting',
          diagnosis: {
            status: 'waiting',
            summary: 'Waiting for URL.',
            checks: [],
            timeline: [{ message: 'Waiting for URL.' }],
          },
        },
      }
    );

    expect(next[0].runtime.diagnosis.summary).toBe('Waiting for URL.');
  });

  test('maps runtime state to the v3 run progress path', () => {
    expect(
      renderer.runProgressIndex({
        runtime: { status: 'starting' },
      })
    ).toBe(1);
    expect(
      renderer.runProgressIndex({
        runtime: { status: 'ready' },
      })
    ).toBe(2);
  });
});
