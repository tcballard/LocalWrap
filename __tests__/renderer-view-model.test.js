require('../public/app.js');

const renderer = global.LocalWrapRenderer;

describe('renderer view-model helpers', () => {
  test('creates a default unsaved project draft', () => {
    expect(renderer.createDefaultDraft({ port: 5173 })).toMatchObject({
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
});
