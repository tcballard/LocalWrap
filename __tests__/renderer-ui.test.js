const fs = require('fs');
const path = require('path');

describe('renderer UI surface', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'public', 'app.html'), 'utf8');

  test('first-run empty state has an Add Project action', () => {
    expect(html).toContain('id="emptyAddProjectBtn"');
    expect(html).toContain('class="empty-task"');
    expect(html).toContain('Add Project');
  });

  test('hidden detail panel stays out of the first-run layout', () => {
    expect(html).toContain('.detail[hidden]');
    expect(html).toContain('display: none');
  });

  test('project form is grouped into calm first-run sections', () => {
    expect(html).toContain('<legend>Project</legend>');
    expect(html).toContain('<legend>Launch</legend>');
    expect(html).toContain('<legend>Options</legend>');
    expect(html).toContain('id="draftNotice"');
  });

  test('project form exposes inline validation message targets', () => {
    for (const id of ['nameMessage', 'cwdMessage', 'commandMessage', 'portMessage', 'urlMessage']) {
      expect(html).toContain(`id="${id}"`);
    }
  });

  test('runtime area exposes log controls and command reveal', () => {
    for (const id of ['revealCommandBtn', 'copyLogsBtn', 'clearLogsBtn', 'commandReveal']) {
      expect(html).toContain(`id="${id}"`);
    }
  });

  test('status strip exposes selected-project context', () => {
    expect(html).toContain('id="statusBar"');
    expect(html).toContain('id="statusRight"');
  });
});
