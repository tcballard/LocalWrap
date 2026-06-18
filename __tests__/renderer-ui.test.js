const fs = require('fs');
const path = require('path');

describe('renderer UI surface', () => {
  const html = fs.readFileSync(path.join(__dirname, '..', 'public', 'app.html'), 'utf8');
  const js = fs.readFileSync(path.join(__dirname, '..', 'public', 'app.js'), 'utf8');

  test('first-run empty state has sample and add project actions', () => {
    expect(html).toContain('id="emptySampleProjectBtn"');
    expect(html).toContain('id="emptyAddProjectBtn"');
    expect(html).toContain('class="empty-task"');
    expect(html).toContain('Try Sample Project');
    expect(html).toContain('Add Project');
    expect(html.indexOf('id="emptySampleProjectBtn"')).toBeLessThan(
      html.indexOf('id="emptyAddProjectBtn"')
    );
    expect(html).toContain('class="btn primary" id="emptySampleProjectBtn"');
    expect(html).toContain('class="btn" id="emptyAddProjectBtn"');
  });

  test('sample action calls preload and selects the created project', () => {
    expect(js).toContain('state.api.createSampleProject');
    expect(js).toContain('const sample = await state.api.createSampleProject();');
    expect(js).toContain('setSelected(sample.id);');
    expect(js).toContain('Sample project ready. Click Save & Start.');
  });

  test('hidden detail panel stays out of the first-run layout', () => {
    expect(html).toContain('.detail[hidden]');
    expect(html).toContain('display: none');
  });

  test('project form is grouped into calm first-run sections', () => {
    expect(html).toContain('id="setupPanel"');
    expect(html).toContain('id="toggleSetupBtn"');
    expect(html).toContain('id="runProgress"');
    expect(html).toContain('<legend>Project</legend>');
    expect(html).toContain('<legend>Launch</legend>');
    expect(html).toContain('<legend>Options</legend>');
    expect(html).toContain('id="draftNotice"');
  });

  test('v3 workspace controls are exposed in the toolbar', () => {
    for (const id of [
      'resumeWorkspaceBtn',
      'workspaceSelect',
      'workspaceNameInput',
      'saveWorkspaceBtn',
      'startAllProjectsBtn',
      'stopAllProjectsBtn',
    ]) {
      expect(html).toContain(`id="${id}"`);
    }

    expect(html).toContain('Resume Workspace');
    expect(html).toContain('Save Workspace');
    expect(html).toContain('Last running workspace');
    expect(html).toContain('Workspace name');
    expect(html).toContain('Start All');
    expect(html).toContain('Stop All');
    expect(js).toContain('saveWorkspaceProfile');
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

  test('launch actions expose Save & Start as the first green run action', () => {
    expect(html).toContain('id="saveAndStartBtn"');
    expect(html).toContain('Save &amp; Start');
    expect(html.indexOf('id="saveAndStartBtn"')).toBeLessThan(html.indexOf('id="startProjectBtn"'));
    expect(js).toContain('saveAndStartProject');
    expect(js).toContain('state.api.startProject(saved.id)');
  });

  test('runtime area exposes an in-app preview surface', () => {
    for (const id of [
      'previewProjectBtn',
      'previewPanel',
      'previewViewport',
      'reloadPreviewBtn',
      'openPreviewExternalBtn',
      'closePreviewBtn',
    ]) {
      expect(html).toContain(`id="${id}"`);
    }

    expect(html.indexOf('id="previewPanel"')).toBeLessThan(html.indexOf('id="doctorPanel"'));
    expect(html).toContain('Preview');
    expect(html).toContain('Browser');
  });

  test('Project Doctor panel appears above logs with safe controls', () => {
    for (const id of [
      'doctorPanel',
      'doctorSummary',
      'doctorChecks',
      'doctorTimeline',
      'copyDoctorReportBtn',
      'revealProjectDirBtn',
      'toggleDoctorBtn',
    ]) {
      expect(html).toContain(`id="${id}"`);
    }

    expect(html.indexOf('id="doctorPanel"')).toBeLessThan(html.indexOf('id="terminal"'));
    expect(html).toContain('Project Doctor');
    expect(html).toContain('Copy Report');
    expect(html).toContain('Reveal Folder');
  });

  test('status strip exposes selected-project context', () => {
    expect(html).toContain('id="statusBar"');
    expect(html).toContain('id="statusRight"');
  });
});
