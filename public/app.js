(function () {
  const ACTIVE_STATUSES = new Set([
    'starting',
    'running',
    'ready',
    'running-unresponsive',
    'stopping',
  ]);
  const AUTO_URL_RE = /^https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\]):\d+$/;
  const FIELD_NAMES = ['name', 'cwd', 'command', 'port', 'url'];
  const DOCTOR_CHECKS = [
    ['directory', 'Directory'],
    ['command', 'Command'],
    ['dependencies', 'Dependencies'],
    ['port', 'Port'],
    ['url', 'URL'],
    ['process', 'Process'],
    ['readiness', 'Readiness'],
  ];
  const DOCTOR_ICONS = {
    pass: 'OK',
    warn: '!',
    fail: 'X',
    running: '...',
    pending: '-',
  };
  const DOCTOR_MUTATING_ACTIONS = new Set(['use-free-port', 'sync-url-to-port']);

  const state = {
    api: null,
    projects: [],
    selectedId: null,
    draft: null,
    scripts: [],
    inspectionWarnings: [],
    validation: null,
    diagnosis: null,
    validationSeq: 0,
    validationTimer: null,
    commandVisible: false,
    elements: {},
  };

  function getAutoUrl(port) {
    return `http://localhost:${port || 3000}`;
  }

  function pathBasename(value) {
    if (!value) return '';
    return String(value).split(/[\\/]/).filter(Boolean).pop() || '';
  }

  function createDefaultDraft(overrides = {}) {
    const port = Number(overrides.port || overrides.suggestedPort || 3000);
    return {
      id: null,
      isDraft: true,
      name: overrides.name || '',
      cwd: overrides.cwd || '',
      command: overrides.command || overrides.recommendedCommand || 'npm run dev',
      port,
      url: overrides.url || overrides.suggestedUrl || getAutoUrl(port),
      autostart: Boolean(overrides.autostart),
      openOnReady: overrides.openOnReady !== false,
      runtime: {
        status: 'stopped',
        pid: null,
        logs: [],
        diagnosis: null,
      },
    };
  }

  function createDefaultDiagnosis() {
    return {
      status: 'idle',
      summary: 'Project Doctor has not checked this project yet.',
      checks: DOCTOR_CHECKS.map(([id, label]) => ({
        id,
        label,
        status: 'pending',
        message: 'Not checked yet.',
        actions: [],
      })),
      timeline: [],
      actions: [],
    };
  }

  function normalizeProjectForView(project) {
    return {
      ...project,
      runtime: {
        status: project.runtime?.status || 'stopped',
        pid: project.runtime?.pid || null,
        logs: project.runtime?.logs || [],
        error: project.runtime?.error || null,
        readinessMessage: project.runtime?.readinessMessage || null,
        lastExitCode: project.runtime?.lastExitCode ?? project.runtime?.exitCode ?? null,
        lastStartedAt: project.runtime?.lastStartedAt || project.runtime?.startedAt || null,
        lastStoppedAt: project.runtime?.lastStoppedAt || project.runtime?.stoppedAt || null,
        diagnosis: project.runtime?.diagnosis || null,
        diagnosisTimeline:
          project.runtime?.diagnosisTimeline || project.runtime?.diagnosis?.timeline || [],
      },
    };
  }

  function mergeProjectEvent(projects, event) {
    return projects.map((project) => {
      if (project.id !== event.projectId) {
        return project;
      }

      return normalizeProjectForView({
        ...project,
        runtime: event.state,
      });
    });
  }

  function isProjectActive(project) {
    return ACTIVE_STATUSES.has(project?.runtime?.status);
  }

  function statusLabel(status) {
    const labels = {
      starting: 'Starting',
      running: 'Running',
      ready: 'Ready',
      'running-unresponsive': 'Running, no response',
      stopping: 'Stopping',
      stopped: 'Stopped',
      failed: 'Failed',
      error: 'Failed',
    };
    return labels[status] || 'Stopped';
  }

  function setStatus(message, type) {
    const statusBar = state.elements.statusBar;
    if (!statusBar) return;

    statusBar.textContent = message;
    statusBar.style.color = type === 'error' ? '#a22222' : '';
  }

  function setStatusRight(message) {
    const statusRight = state.elements.statusRight;
    if (!statusRight) return;

    statusRight.textContent = message;
  }

  function updateStatusRight() {
    const project = selectedProject();
    if (!project) {
      setStatusRight('No project selected');
      return;
    }

    if (project.isDraft) {
      const draft = readFormProject();
      setStatusRight(`${draft.name || 'New project'} | Draft | Port ${draft.port || '-'}`);
      return;
    }

    const formProject = readFormProject();
    const dirtySuffix = isFormDirty() ? ' | Unsaved changes' : '';
    setStatusRight(
      `${project.name} | ${statusLabel(project.runtime?.status)} | Port ${
        formProject.port || project.port || '-'
      }${dirtySuffix}`
    );
  }

  function showError(error) {
    setStatus(error?.message || String(error), 'error');
  }

  function selectedProject() {
    if (state.draft) {
      return state.draft;
    }
    return state.projects.find((project) => project.id === state.selectedId) || null;
  }

  function selectedSavedProject() {
    return state.projects.find((project) => project.id === state.selectedId) || null;
  }

  function readFormProject() {
    const project = selectedProject() || createDefaultDraft();
    return {
      id: project.id,
      isDraft: Boolean(project.isDraft),
      name:
        state.elements.nameInput.value.trim() ||
        pathBasename(state.elements.cwdInput.value) ||
        'Untitled Project',
      cwd: state.elements.cwdInput.value,
      command: state.elements.commandInput.value.trim(),
      port: Number(state.elements.portInput.value),
      url: state.elements.urlInput.value.trim(),
      autostart: state.elements.autostartInput.checked,
      openOnReady: state.elements.openOnReadyInput.checked,
    };
  }

  function projectFields(project) {
    if (!project) return null;
    return {
      name: project.name || '',
      cwd: project.cwd || '',
      command: project.command || '',
      port: Number(project.port || 3000),
      url: project.url || getAutoUrl(project.port),
      autostart: Boolean(project.autostart),
      openOnReady: Boolean(project.openOnReady),
    };
  }

  function isFormDirty() {
    if (state.draft) {
      return true;
    }

    const saved = selectedSavedProject();
    if (!saved) {
      return false;
    }

    const current = projectFields(readFormProject());
    const original = projectFields(saved);
    return Object.keys(original).some((key) => current[key] !== original[key]);
  }

  function setSelected(projectId) {
    state.selectedId = projectId;
    state.draft = null;
    state.scripts = [];
    state.inspectionWarnings = [];
    state.validation = null;
    state.diagnosis = null;
    state.commandVisible = false;
    const project = selectedProject();
    render();
    if (project?.cwd) {
      discoverScripts(project.cwd);
    }
    scheduleValidation(0);
  }

  async function loadProjects(projects) {
    if (Array.isArray(projects)) {
      state.projects = projects.map(normalizeProjectForView);
    } else {
      state.projects = (await state.api.listProjects()).map(normalizeProjectForView);
    }

    if (
      !state.draft &&
      (!state.selectedId || !state.projects.some((project) => project.id === state.selectedId))
    ) {
      state.selectedId = state.projects[0]?.id || null;
    }

    render();
    scheduleValidation(0);
  }

  function render() {
    renderProjectList();
    renderDetail();
    updateStatusRight();
  }

  function renderProjectList() {
    const list = state.elements.projectList;
    list.textContent = '';

    if (state.projects.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'project-subtitle';
      empty.textContent = 'Use Add Project to import a folder';
      list.appendChild(empty);
      return;
    }

    state.projects.forEach((project) => {
      const row = document.createElement('button');
      row.type = 'button';
      row.className = `project-row${project.id === state.selectedId && !state.draft ? ' selected' : ''}`;
      row.addEventListener('click', () => setSelected(project.id));

      const dot = document.createElement('span');
      dot.className = `status-dot ${project.runtime.status}`;

      const text = document.createElement('span');
      const name = document.createElement('div');
      name.className = 'project-name';
      name.textContent = project.name;

      const subtitle = document.createElement('div');
      subtitle.className = 'project-subtitle';
      subtitle.textContent = `${statusLabel(project.runtime.status)} | ${project.command}`;

      text.appendChild(name);
      text.appendChild(subtitle);
      row.appendChild(dot);
      row.appendChild(text);
      list.appendChild(row);
    });
  }

  function renderDetail() {
    const project = selectedProject();
    const hasProject = Boolean(project);

    state.elements.emptyState.classList.toggle('visible', !hasProject);
    state.elements.projectDetail.hidden = !hasProject;
    state.elements.saveProjectBtn.disabled = !hasProject;
    state.elements.deleteProjectBtn.disabled = !hasProject || project?.isDraft;

    if (!hasProject) {
      clearFieldMessages();
      setDraftNotice('');
      updateActionState();
      return;
    }

    state.elements.nameInput.value = project.name || '';
    state.elements.cwdInput.value = project.cwd || '';
    state.elements.commandInput.value = project.command || '';
    state.elements.portInput.value = project.port || 3000;
    state.elements.urlInput.value = project.url || getAutoUrl(project.port);
    state.elements.autostartInput.checked = Boolean(project.autostart);
    state.elements.openOnReadyInput.checked = Boolean(project.openOnReady);

    renderScripts();
    renderRuntime(project);
    applyValidationMessages();
    updateCommandReveal();
    updateActionState();
  }

  function diagnosisForProject(project) {
    if (!project) {
      return createDefaultDiagnosis();
    }

    return project.runtime?.diagnosis || state.diagnosis || createDefaultDiagnosis();
  }

  function latestTimelineText(diagnosis) {
    const latest = diagnosis.timeline?.at(-1);
    if (!latest) {
      return 'No checks yet.';
    }
    return latest.message;
  }

  function isDoctorActionDisabled(actionId, project) {
    if (!project) {
      return true;
    }

    if (actionId === 'reveal-command') {
      return false;
    }

    const saved = Boolean(project && !project.isDraft);
    if (actionId === 'copy-report' || actionId === 'reveal-directory') {
      return !saved;
    }

    if (DOCTOR_MUTATING_ACTIONS.has(actionId)) {
      if (project.isDraft) {
        return false;
      }
      return !saved || isProjectActive(project) || isFormDirty();
    }

    return true;
  }

  function renderDoctor(project) {
    const diagnosis = diagnosisForProject(project);
    state.elements.doctorPanel.className = `doctor ${diagnosis.status || 'idle'}`;
    state.elements.doctorSummary.textContent = diagnosis.summary || 'Not checked yet.';
    state.elements.doctorTimeline.textContent = latestTimelineText(diagnosis);
    state.elements.copyDoctorReportBtn.disabled = isDoctorActionDisabled('copy-report', project);
    state.elements.revealProjectDirBtn.disabled = isDoctorActionDisabled(
      'reveal-directory',
      project
    );
    state.elements.doctorChecks.textContent = '';

    diagnosis.checks.forEach((check) => {
      const row = document.createElement('div');
      row.className = `doctor-row ${check.status || 'pending'}`;

      const stateEl = document.createElement('span');
      stateEl.className = 'doctor-state';
      stateEl.textContent = DOCTOR_ICONS[check.status] || '-';

      const labelEl = document.createElement('span');
      labelEl.className = 'doctor-label';
      labelEl.textContent = check.label;

      const messageEl = document.createElement('span');
      messageEl.className = 'doctor-message';
      messageEl.textContent = check.message;

      row.appendChild(stateEl);
      row.appendChild(labelEl);
      row.appendChild(messageEl);

      const action = check.actions?.[0];
      if (action) {
        const actionBtn = document.createElement('button');
        actionBtn.type = 'button';
        actionBtn.className = 'btn';
        actionBtn.dataset.doctorAction = action.id;
        actionBtn.disabled = isDoctorActionDisabled(action.id, project);
        actionBtn.textContent = action.label;
        row.appendChild(actionBtn);
      } else {
        row.appendChild(document.createElement('span'));
      }

      state.elements.doctorChecks.appendChild(row);
    });
  }

  function renderRuntime(project) {
    const runtime = project.runtime || { status: 'stopped', logs: [] };
    const logs = runtime.logs && runtime.logs.length > 0 ? runtime.logs : ['No output yet.'];

    renderDoctor(project);
    state.elements.statusBadge.className = `badge ${runtime.status || 'stopped'}`;
    state.elements.statusBadge.textContent = statusLabel(runtime.status);
    state.elements.pidLabel.textContent = `PID: ${runtime.pid || '-'}`;
    state.elements.readinessLabel.textContent = runtime.readinessMessage || '';
    state.elements.urlLabel.textContent = project.url || getAutoUrl(project.port);

    state.elements.terminal.textContent = '';
    logs.forEach((line) => {
      const row = document.createElement('div');
      row.textContent = line;
      state.elements.terminal.appendChild(row);
    });
    state.elements.terminal.scrollTop = state.elements.terminal.scrollHeight;
    updateActionState();
  }

  function renderScripts() {
    const select = state.elements.scriptSelect;
    const command = state.elements.commandInput.value;
    select.textContent = '';

    if (state.scripts.length === 0) {
      const option = document.createElement('option');
      option.value = '';
      option.textContent = 'None found';
      select.appendChild(option);
      select.disabled = true;
      return;
    }

    const blank = document.createElement('option');
    blank.value = '';
    blank.textContent = 'Choose script';
    select.appendChild(blank);

    state.scripts.forEach((script) => {
      const option = document.createElement('option');
      option.value = script.command;
      option.textContent = script.command ? `${script.name} (${script.command})` : script.name;
      select.appendChild(option);
    });

    select.disabled = false;
    select.value = state.scripts.some((script) => script.command === command) ? command : '';
  }

  function findMessage(messages, field) {
    return messages.find((message) => message.field === field);
  }

  function inspectionWarningFor(field) {
    return state.inspectionWarnings.find((warning) => warning.field === field);
  }

  function clearFieldMessages() {
    FIELD_NAMES.forEach((field) => {
      const fieldEl = state.elements[`${field}Field`];
      const messageEl = state.elements[`${field}Message`];
      if (!fieldEl || !messageEl) return;

      fieldEl.classList.remove('invalid', 'warning');
      messageEl.textContent = '';
    });
  }

  function setDraftNotice(message, type = 'warning') {
    const notice = state.elements.draftNotice;
    if (!notice) return;

    notice.textContent = message || '';
    notice.classList.toggle('visible', Boolean(message));
    notice.classList.toggle('error', type === 'error');
    notice.classList.toggle('info', type === 'info');
  }

  function updateDraftNotice() {
    const project = selectedProject();
    if (!project) {
      setDraftNotice('');
      return;
    }

    const validation = state.validation || { errors: [], warnings: [] };
    if (validation.errors.length > 0) {
      setDraftNotice('Fix the highlighted fields before saving.', 'error');
      return;
    }

    const warning = validation.warnings[0] || state.inspectionWarnings[0];
    if (warning) {
      setDraftNotice(warning.message);
      return;
    }

    if (project.isDraft) {
      setDraftNotice('Defaults loaded. Save this project when it looks right.', 'info');
      return;
    }

    if (isFormDirty()) {
      setDraftNotice('Unsaved changes. Save before starting or restarting.');
      return;
    }

    setDraftNotice('');
  }

  function applyValidationMessages() {
    clearFieldMessages();

    const validation = state.validation || { errors: [], warnings: [] };
    FIELD_NAMES.forEach((field) => {
      const fieldEl = state.elements[`${field}Field`];
      const messageEl = state.elements[`${field}Message`];
      if (!fieldEl || !messageEl) return;

      const error = findMessage(validation.errors, field);
      const warning = findMessage(validation.warnings, field) || inspectionWarningFor(field);

      if (error) {
        fieldEl.classList.add('invalid');
        messageEl.textContent = error.message;
      } else if (warning) {
        fieldEl.classList.add('warning');
        messageEl.textContent = warning.message;
      }
    });
    updateDraftNotice();
  }

  function updateActionState() {
    const project = selectedProject();
    const saved = Boolean(project && !project.isDraft);
    const active = isProjectActive(project);
    const validationKnown = Boolean(state.validation);
    const valid = validationKnown && state.validation.valid;
    const dirty = isFormDirty();
    const ready = project?.runtime?.status === 'ready';

    state.elements.saveProjectBtn.disabled = !project || !valid;
    state.elements.deleteProjectBtn.disabled = !saved;
    state.elements.startProjectBtn.disabled = !saved || !valid || dirty || active;
    state.elements.stopProjectBtn.disabled =
      !saved || !active || project.runtime.status === 'stopping';
    state.elements.restartProjectBtn.disabled =
      !saved || !valid || dirty || project.runtime.status === 'stopping';
    state.elements.openProjectBtn.disabled = !saved || !ready;
    state.elements.copyLogsBtn.disabled = !saved;
    state.elements.clearLogsBtn.disabled = !saved;
    state.elements.revealCommandBtn.disabled = !project;
    if (state.elements.doctorPanel) {
      renderDoctor(project);
    }
    updateStatusRight();
  }

  async function discoverScripts(cwd) {
    if (!cwd) {
      state.scripts = [];
      renderScripts();
      return;
    }

    try {
      state.scripts = await state.api.discoverScripts(cwd);
      renderScripts();
    } catch (error) {
      state.scripts = [];
      renderScripts();
      showError(error);
    }
  }

  function scheduleValidation(delay = 200) {
    clearTimeout(state.validationTimer);
    state.validationTimer = setTimeout(() => {
      validateCurrentDraft({ silent: true }).catch(showError);
    }, delay);
  }

  async function validateCurrentDraft({ silent = false } = {}) {
    const project = selectedProject();
    if (!project) {
      state.validation = null;
      state.diagnosis = null;
      applyValidationMessages();
      updateActionState();
      return { valid: false, errors: [], warnings: [] };
    }

    const seq = (state.validationSeq += 1);
    const result = await state.api.validateProjectDraft(readFormProject());
    if (seq !== state.validationSeq) {
      return result;
    }

    state.validation = result;
    if (state.api.diagnoseProjectDraft) {
      const diagnosis = await state.api.diagnoseProjectDraft(readFormProject());
      if (seq !== state.validationSeq) {
        return result;
      }
      state.diagnosis = diagnosis;
    }
    applyValidationMessages();
    updateActionState();
    renderDoctor(selectedProject());

    if (!silent && !result.valid) {
      setStatus('Fix project details before continuing.', 'error');
    }

    return result;
  }

  function writeProfileToForm(profile) {
    state.elements.nameInput.value = profile.name || pathBasename(profile.cwd);
    state.elements.cwdInput.value = profile.cwd || '';
    state.elements.commandInput.value = profile.recommendedCommand || 'npm run dev';
    state.elements.portInput.value = profile.suggestedPort || 3000;
    state.elements.urlInput.value = profile.suggestedUrl || getAutoUrl(profile.suggestedPort);
    state.scripts = profile.scripts || [];
    state.inspectionWarnings = profile.warnings || [];
    renderScripts();
  }

  async function importProjectFromDirectory() {
    const cwd = await state.api.selectDirectory();
    if (!cwd) return;

    const profile = await state.api.inspectDirectory(cwd);
    state.draft = createDefaultDraft(profile);
    state.selectedId = null;
    state.scripts = profile.scripts || [];
    state.inspectionWarnings = profile.warnings || [];
    state.validation = null;
    state.diagnosis = null;
    state.commandVisible = false;
    render();
    await validateCurrentDraft({ silent: true });

    if (profile.warnings?.length) {
      setStatus(profile.warnings[0].message);
    } else {
      setStatus(`Ready to save ${profile.name}.`);
    }
  }

  async function browseDirectory() {
    const cwd = await state.api.selectDirectory();
    if (!cwd) return;

    const profile = await state.api.inspectDirectory(cwd);
    if (state.draft) {
      state.draft = createDefaultDraft({
        ...state.draft,
        ...profile,
        command: profile.recommendedCommand,
        port: profile.suggestedPort,
        url: profile.suggestedUrl,
      });
      state.scripts = profile.scripts || [];
      state.inspectionWarnings = profile.warnings || [];
      render();
    } else {
      writeProfileToForm(profile);
      applyValidationMessages();
      updateActionState();
    }

    await validateCurrentDraft({ silent: true });
  }

  async function saveProject() {
    const validation = await validateCurrentDraft({ silent: false });
    if (!validation.valid) {
      return;
    }

    const formProject = readFormProject();
    try {
      let saved;
      if (formProject.isDraft) {
        saved = await state.api.createProject(formProject);
      } else {
        saved = await state.api.updateProject(formProject.id, formProject);
      }

      state.draft = null;
      state.selectedId = saved.id;
      state.inspectionWarnings = [];
      await loadProjects();
      setStatus(`Saved ${saved.name}.`);
    } catch (error) {
      showError(error);
    }
  }

  async function deleteProject() {
    const project = selectedProject();
    if (!project || project.isDraft) return;
    if (!window.confirm(`Delete ${project.name}?`)) return;

    try {
      await state.api.deleteProject(project.id);
      state.selectedId = null;
      state.validation = null;
      state.diagnosis = null;
      await loadProjects();
      setStatus(`Deleted ${project.name}.`);
    } catch (error) {
      showError(error);
    }
  }

  async function runProjectAction(actionName) {
    const project = selectedProject();
    if (!project || project.isDraft) return;

    const validation = await validateCurrentDraft({ silent: true });
    if (!validation.valid) {
      setStatus('Fix project details before starting.', 'error');
      return;
    }

    if (isFormDirty()) {
      setStatus('Save changes before starting.', 'error');
      return;
    }

    const labels = {
      startProject: 'Started',
      stopProject: 'Stopping',
      restartProject: 'Restarted',
      openProject: 'Opened',
    };

    try {
      await state.api[actionName](project.id);
      setStatus(`${labels[actionName]} ${project.name}.`);
    } catch (error) {
      showError(error);
    }
  }

  async function clearLogs() {
    const project = selectedProject();
    if (!project || project.isDraft) return;

    try {
      await state.api.clearProjectLogs(project.id);
      setStatus(`Cleared logs for ${project.name}.`);
    } catch (error) {
      showError(error);
    }
  }

  async function copyLogs() {
    const project = selectedProject();
    if (!project || project.isDraft) return;

    try {
      const result = await state.api.copyProjectLogs(project.id);
      setStatus(`Copied ${result.copied} log line(s).`);
    } catch (error) {
      showError(error);
    }
  }

  async function applyDraftDoctorAction(actionId) {
    if (actionId === 'sync-url-to-port') {
      state.elements.urlInput.value = getAutoUrl(Number(state.elements.portInput.value));
      handleFormChange();
      setStatus('Synced URL to the selected port.');
      return;
    }

    if (actionId === 'use-free-port') {
      const oldPort = Number(state.elements.portInput.value);
      const port = await state.api.suggestPort(oldPort || 3000);
      const shouldUpdateUrl =
        !state.elements.urlInput.value || AUTO_URL_RE.test(state.elements.urlInput.value);
      state.elements.portInput.value = port;
      if (shouldUpdateUrl) {
        state.elements.urlInput.value = getAutoUrl(port);
      }
      handleFormChange();
      setStatus(`Using free port ${port}.`);
    }
  }

  async function handleDoctorAction(actionId) {
    const project = selectedProject();
    if (!project) return;

    if (actionId === 'reveal-command') {
      toggleCommandReveal();
      return;
    }

    if (project.isDraft) {
      await applyDraftDoctorAction(actionId);
      return;
    }

    if (actionId === 'copy-report') {
      const result = await state.api.copyDoctorReport(project.id);
      setStatus(`Copied Doctor report (${result.lines} line(s)).`);
      return;
    }

    if (actionId === 'reveal-directory') {
      await state.api.revealProjectDirectory(project.id);
      setStatus(`Revealed ${project.name}.`);
      return;
    }

    if (DOCTOR_MUTATING_ACTIONS.has(actionId)) {
      if (isProjectActive(project)) {
        setStatus('Stop the project before applying Doctor fixes.', 'error');
        return;
      }
      if (isFormDirty()) {
        setStatus('Save changes before applying Doctor fixes.', 'error');
        return;
      }

      const updated = await state.api.applyDoctorAction(project.id, actionId);
      state.selectedId = updated.id;
      await loadProjects();
      setStatus(`Applied Doctor fix for ${updated.name}.`);
    }
  }

  function updateCommandReveal() {
    const project = selectedProject();
    state.elements.commandReveal.hidden = !state.commandVisible || !project;
    state.elements.commandReveal.textContent = project ? state.elements.commandInput.value : '';
  }

  function toggleCommandReveal() {
    state.commandVisible = !state.commandVisible;
    updateCommandReveal();
  }

  function handleFormChange() {
    updateCommandReveal();
    scheduleValidation();
    updateActionState();
    updateDraftNotice();
  }

  function handlePortInput() {
    const urlInput = state.elements.urlInput;
    const port = Number(state.elements.portInput.value);
    if (!urlInput.value || AUTO_URL_RE.test(urlInput.value)) {
      urlInput.value = getAutoUrl(port);
    }
    handleFormChange();
  }

  function wireControls() {
    state.elements.addProjectBtn.addEventListener('click', () =>
      importProjectFromDirectory().catch(showError)
    );
    state.elements.emptyAddProjectBtn.addEventListener('click', () =>
      importProjectFromDirectory().catch(showError)
    );
    state.elements.saveProjectBtn.addEventListener('click', saveProject);
    state.elements.deleteProjectBtn.addEventListener('click', deleteProject);
    state.elements.refreshBtn.addEventListener('click', () => loadProjects().catch(showError));
    state.elements.browseDirBtn.addEventListener('click', () => browseDirectory().catch(showError));
    state.elements.startProjectBtn.addEventListener('click', () =>
      runProjectAction('startProject')
    );
    state.elements.stopProjectBtn.addEventListener('click', () => runProjectAction('stopProject'));
    state.elements.restartProjectBtn.addEventListener('click', () =>
      runProjectAction('restartProject')
    );
    state.elements.openProjectBtn.addEventListener('click', () => runProjectAction('openProject'));
    state.elements.clearLogsBtn.addEventListener('click', () => clearLogs().catch(showError));
    state.elements.copyLogsBtn.addEventListener('click', () => copyLogs().catch(showError));
    state.elements.revealCommandBtn.addEventListener('click', toggleCommandReveal);
    state.elements.copyDoctorReportBtn.addEventListener('click', () =>
      handleDoctorAction('copy-report').catch(showError)
    );
    state.elements.revealProjectDirBtn.addEventListener('click', () =>
      handleDoctorAction('reveal-directory').catch(showError)
    );
    state.elements.doctorChecks.addEventListener('click', (event) => {
      const button = event.target.closest('[data-doctor-action]');
      if (!button || button.disabled) return;
      handleDoctorAction(button.dataset.doctorAction).catch(showError);
    });
    state.elements.portInput.addEventListener('input', handlePortInput);

    ['nameInput', 'commandInput', 'urlInput', 'autostartInput', 'openOnReadyInput'].forEach(
      (id) => {
        state.elements[id].addEventListener('input', handleFormChange);
        state.elements[id].addEventListener('change', handleFormChange);
      }
    );

    state.elements.scriptSelect.addEventListener('change', () => {
      if (state.elements.scriptSelect.value) {
        state.elements.commandInput.value = state.elements.scriptSelect.value;
        handleFormChange();
      }
    });
  }

  function collectElements() {
    [
      'projectList',
      'emptyState',
      'projectDetail',
      'addProjectBtn',
      'emptyAddProjectBtn',
      'draftNotice',
      'saveProjectBtn',
      'deleteProjectBtn',
      'refreshBtn',
      'nameField',
      'nameMessage',
      'cwdField',
      'cwdMessage',
      'portField',
      'portMessage',
      'commandField',
      'commandMessage',
      'urlField',
      'urlMessage',
      'nameInput',
      'cwdInput',
      'browseDirBtn',
      'portInput',
      'commandInput',
      'scriptSelect',
      'urlInput',
      'autostartInput',
      'openOnReadyInput',
      'startProjectBtn',
      'stopProjectBtn',
      'restartProjectBtn',
      'openProjectBtn',
      'revealCommandBtn',
      'copyLogsBtn',
      'clearLogsBtn',
      'commandReveal',
      'doctorPanel',
      'doctorSummary',
      'doctorChecks',
      'doctorTimeline',
      'copyDoctorReportBtn',
      'revealProjectDirBtn',
      'statusBadge',
      'pidLabel',
      'readinessLabel',
      'urlLabel',
      'terminal',
      'statusBar',
      'statusRight',
      'versionLabel',
    ].forEach((id) => {
      state.elements[id] = document.getElementById(id);
    });
  }

  function subscribeToEvents() {
    state.api.onProjectListChanged((projects) => {
      loadProjects(projects).catch(showError);
    });

    state.api.onProjectEvent((event) => {
      state.projects = mergeProjectEvent(state.projects, event);
      renderProjectList();
      const project = selectedProject();
      if (project && project.id === event.projectId) {
        renderRuntime(project);
      }
    });
  }

  async function init() {
    collectElements();
    state.api = window.localwrapAPI;

    if (!state.api) {
      setStatus('LocalWrap desktop API unavailable.', 'error');
      return;
    }

    state.elements.versionLabel.textContent = `v${state.api.version}`;
    wireControls();
    subscribeToEvents();
    await loadProjects();
  }

  const testApi = {
    ACTIVE_STATUSES,
    createDefaultDraft,
    getAutoUrl,
    isProjectActive,
    mergeProjectEvent,
    normalizeProjectForView,
    pathBasename,
    projectFields,
    statusLabel,
  };

  if (typeof globalThis !== 'undefined') {
    globalThis.LocalWrapRenderer = testApi;
  }

  if (typeof window !== 'undefined' && typeof document !== 'undefined') {
    window.addEventListener('DOMContentLoaded', () => {
      init().catch(showError);
    });
  }
})();
