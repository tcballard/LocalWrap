(function () {
  // Loaded by the shared-constants.js script tag (or by tests via require)
  // before this file; the single source shared with the main process.
  const SHARED = globalThis.LocalWrapConstants;
  if (!SHARED) {
    throw new Error('shared-constants.js must be loaded before app.js');
  }

  const ACTIVE_STATUSES = new Set(SHARED.ACTIVE_STATUSES);
  const AUTO_URL_RE = SHARED.AUTO_LOCAL_URL_RE;
  const FIELD_NAMES = ['name', 'cwd', 'command', 'port', 'url'];
  const DOCTOR_CHECKS = SHARED.DOCTOR_CHECKS;
  const DOCTOR_ICONS = {
    pass: 'OK',
    warn: '!',
    fail: 'X',
    running: '...',
    pending: '-',
  };
  const DOCTOR_MUTATING_ACTIONS = new Set(SHARED.DOCTOR_MUTATING_ACTIONS);
  const DOCTOR_ACTION = SHARED.DOCTOR_ACTIONS;

  const state = {
    api: null,
    projects: [],
    workspace: {
      lastRunningProjectIds: [],
      savedWorkspaces: [],
    },
    workspaceDiagnosis: null,
    selectedWorkspaceId: '',
    selectedId: null,
    draft: null,
    scripts: [],
    inspectionWarnings: [],
    validation: null,
    diagnosis: null,
    validationSeq: 0,
    validationTimer: null,
    commandVisible: false,
    previewVisible: false,
    previewProjectId: null,
    previewUrl: '',
    previewStatus: 'idle',
    previewResizeObserver: null,
    collapsedSections: {
      setup: false,
      doctor: false,
    },
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

  function createDefaultWorkspaceDiagnosis() {
    return {
      status: 'empty',
      summary: 'No saved projects to diagnose.',
      target: {
        kind: 'all-projects',
        profileId: null,
        name: 'Saved projects',
        projectIds: [],
      },
      totals: {
        projects: 0,
        ready: 0,
        warnings: 0,
        blockers: 0,
      },
      startableProjectIds: [],
      blockedProjectIds: [],
      checks: [],
      projects: [],
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

  function normalizeWorkspaceForView(workspace = {}) {
    return {
      lastRunningProjectIds: Array.isArray(workspace.lastRunningProjectIds)
        ? workspace.lastRunningProjectIds
        : [],
      savedWorkspaces: Array.isArray(workspace.savedWorkspaces) ? workspace.savedWorkspaces : [],
      updatedAt: workspace.updatedAt || null,
    };
  }

  function normalizeWorkspaceDiagnosisForView(diagnosis = {}) {
    const fallback = createDefaultWorkspaceDiagnosis();
    return {
      ...fallback,
      ...diagnosis,
      target: {
        ...fallback.target,
        ...(diagnosis.target || {}),
      },
      totals: {
        ...fallback.totals,
        ...(diagnosis.totals || {}),
      },
      startableProjectIds: Array.isArray(diagnosis.startableProjectIds)
        ? diagnosis.startableProjectIds
        : [],
      blockedProjectIds: Array.isArray(diagnosis.blockedProjectIds)
        ? diagnosis.blockedProjectIds
        : [],
      checks: Array.isArray(diagnosis.checks) ? diagnosis.checks : [],
      projects: Array.isArray(diagnosis.projects) ? diagnosis.projects : [],
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
    resetPreviewState();
    closePreviewInMain();
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

  function sectionButtonText(collapsed) {
    return collapsed ? 'Expand' : 'Collapse';
  }

  function sectionButtonIcon(collapsed) {
    return collapsed ? '▸' : '▾';
  }

  function renderSetup(project) {
    const collapsed = state.collapsedSections.setup;
    state.elements.setupPanel.classList.toggle('collapsed', collapsed);
    state.elements.setupFields.hidden = collapsed;
    state.elements.toggleSetupBtn.innerHTML = `<span class="btn-icon">${sectionButtonIcon(
      collapsed
    )}</span>${sectionButtonText(collapsed)}`;

    if (!project) {
      state.elements.setupSummary.textContent = 'Directory, command, and URL';
      return;
    }

    const formProject = readFormProject();
    state.elements.setupSummary.textContent = `${formProject.command || 'No command'} | ${
      formProject.url || getAutoUrl(formProject.port)
    }`;
  }

  function toggleSection(section) {
    state.collapsedSections[section] = !state.collapsedSections[section];
    const project = selectedProject();
    if (section === 'setup') {
      renderSetup(project);
    }
    if (section === 'doctor') {
      renderDoctor(project);
    }
    if (section === 'setup' || section === 'doctor') {
      window.requestAnimationFrame(() => {
        syncPreviewBounds().catch(showError);
      });
    }
  }

  async function loadProjects(projects) {
    if (Array.isArray(projects)) {
      state.projects = projects.map(normalizeProjectForView);
    } else {
      state.projects = (await state.api.listProjects()).map(normalizeProjectForView);
    }

    if (state.api.getWorkspace) {
      state.workspace = normalizeWorkspaceForView(await state.api.getWorkspace());
      if (
        state.selectedWorkspaceId &&
        !state.workspace.savedWorkspaces.some((profile) => profile.id === state.selectedWorkspaceId)
      ) {
        state.selectedWorkspaceId = '';
      }
      syncDefaultWorkspaceSelection();
    }

    if (
      !state.draft &&
      (!state.selectedId || !state.projects.some((project) => project.id === state.selectedId))
    ) {
      state.selectedId = state.projects[0]?.id || null;
    }

    if (state.previewProjectId) {
      const previewProject = state.projects.find(
        (project) => project.id === state.previewProjectId
      );
      if (!previewProject || previewProject.runtime?.status !== 'ready') {
        resetPreviewState();
        closePreviewInMain();
      }
    }

    await loadWorkspaceDiagnosis();
    render();
    scheduleValidation(0);
  }

  function render() {
    renderProjectList();
    renderDetail();
    renderWorkspaceDoctor();
    updateWorkspaceActions();
    updateStatusRight();
  }

  function activeProjects() {
    return state.projects.filter((project) => isProjectActive(project));
  }

  function syncDefaultWorkspaceSelection() {
    const profiles = state.workspace.savedWorkspaces || [];
    if (!state.selectedWorkspaceId && profiles.length === 1) {
      state.selectedWorkspaceId = profiles[0].id;
    }
  }

  function hasResumableWorkspace() {
    const savedIds = new Set(state.projects.map((project) => project.id));
    const selected = selectedWorkspaceProfile();
    const projectIds = selected?.projectIds || state.workspace.lastRunningProjectIds || [];
    return projectIds.some((projectId) => savedIds.has(projectId));
  }

  function selectedWorkspaceProfile() {
    if (!state.selectedWorkspaceId) {
      return null;
    }
    return (
      (state.workspace.savedWorkspaces || []).find(
        (profile) => profile.id === state.selectedWorkspaceId
      ) || null
    );
  }

  function workspaceProjectCount(profile) {
    const savedIds = new Set(state.projects.map((project) => project.id));
    return (profile?.projectIds || []).filter((projectId) => savedIds.has(projectId)).length;
  }

  async function loadWorkspaceDiagnosis({ rerender = false } = {}) {
    if (!state.api?.diagnoseWorkspace) {
      state.workspaceDiagnosis = createDefaultWorkspaceDiagnosis();
      return state.workspaceDiagnosis;
    }

    state.workspaceDiagnosis = normalizeWorkspaceDiagnosisForView(
      await state.api.diagnoseWorkspace(state.selectedWorkspaceId || null)
    );

    if (rerender) {
      renderWorkspaceDoctor();
      updateWorkspaceActions();
    }

    return state.workspaceDiagnosis;
  }

  function renderProjectList() {
    const list = state.elements.projectList;
    list.textContent = '';

    if (state.projects.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'project-subtitle';
      empty.textContent = 'Try the sample or add a folder';
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

  function workspaceDoctorStatusLabel(status) {
    const labels = {
      ready: 'Ready',
      attention: 'Attention',
      blocked: 'Blocked',
      empty: 'Empty',
    };
    return labels[status] || 'Checking';
  }

  function renderWorkspaceDoctor() {
    const panel = state.elements.workspaceDoctorPanel;
    if (!panel) return;

    const diagnosis = state.workspaceDiagnosis || createDefaultWorkspaceDiagnosis();
    panel.hidden = state.projects.length === 0;
    panel.className = `workspace-doctor ${diagnosis.status || 'empty'}`;
    state.elements.workspaceDoctorBadge.className = `badge ${diagnosis.status || 'empty'}`;
    state.elements.workspaceDoctorBadge.textContent = workspaceDoctorStatusLabel(diagnosis.status);
    state.elements.workspaceDoctorSummary.textContent = diagnosis.summary || 'No diagnosis yet.';
    state.elements.workspaceDoctorTarget.textContent = diagnosis.target?.name || 'Saved projects';
    state.elements.workspaceDoctorTotals.textContent = `${diagnosis.totals.projects} project(s) | ${diagnosis.totals.ready} ready | ${diagnosis.totals.warnings} attention | ${diagnosis.totals.blockers} blocked`;

    state.elements.workspaceDoctorChecks.textContent = '';
    diagnosis.checks.forEach((check) => {
      const row = document.createElement('div');
      row.className = `workspace-doctor-check ${check.status || 'pending'}`;

      const stateEl = document.createElement('span');
      stateEl.className = 'workspace-doctor-state';
      stateEl.textContent = DOCTOR_ICONS[check.status] || '-';

      const labelEl = document.createElement('span');
      labelEl.className = 'workspace-doctor-label';
      labelEl.textContent = check.label;

      const messageEl = document.createElement('span');
      messageEl.className = 'workspace-doctor-message';
      messageEl.textContent = check.message;

      row.appendChild(stateEl);
      row.appendChild(labelEl);
      row.appendChild(messageEl);
      state.elements.workspaceDoctorChecks.appendChild(row);
    });

    state.elements.workspaceDoctorProjects.textContent = '';
    diagnosis.projects.forEach((project) => {
      const row = document.createElement('button');
      row.type = 'button';
      row.className = `workspace-doctor-project ${project.status || 'ready'}`;
      row.addEventListener('click', () => {
        if (state.projects.some((savedProject) => savedProject.id === project.id)) {
          setSelected(project.id);
        }
      });

      const name = document.createElement('span');
      name.className = 'workspace-doctor-project-name';
      name.textContent = project.name;

      const status = document.createElement('span');
      status.className = 'workspace-doctor-project-status';
      status.textContent = workspaceDoctorStatusLabel(project.status);

      const summary = document.createElement('span');
      summary.className = 'workspace-doctor-project-summary';
      summary.textContent = project.summary;

      row.appendChild(name);
      row.appendChild(status);
      row.appendChild(summary);
      state.elements.workspaceDoctorProjects.appendChild(row);
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

    renderSetup(project);
    renderRunProgress(project);
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

    if (actionId === DOCTOR_ACTION.REVEAL_COMMAND) {
      return false;
    }

    const saved = Boolean(project && !project.isDraft);
    if (actionId === DOCTOR_ACTION.COPY_REPORT || actionId === DOCTOR_ACTION.REVEAL_DIRECTORY) {
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
    const collapsed = state.collapsedSections.doctor;
    state.elements.doctorPanel.className = `doctor ${diagnosis.status || 'idle'}${
      collapsed ? ' collapsed' : ''
    }`;
    state.elements.doctorSummary.textContent = diagnosis.summary || 'Not checked yet.';
    state.elements.doctorTimeline.textContent = latestTimelineText(diagnosis);
    state.elements.toggleDoctorBtn.innerHTML = `<span class="btn-icon">${sectionButtonIcon(
      collapsed
    )}</span>${sectionButtonText(collapsed)}`;
    state.elements.copyDoctorReportBtn.disabled = isDoctorActionDisabled(
      DOCTOR_ACTION.COPY_REPORT,
      project
    );
    state.elements.revealProjectDirBtn.disabled = isDoctorActionDisabled(
      DOCTOR_ACTION.REVEAL_DIRECTORY,
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

    renderPreview(project);
    renderDoctor(project);
    renderRunProgress(project);
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

  function runProgressIndex(project) {
    if (!project) return -1;
    if (state.previewVisible && state.previewProjectId === project.id) return 3;
    if (project.runtime?.status === 'ready') return 2;
    if (isProjectActive(project)) return 1;
    return state.validation?.valid ? 0 : -1;
  }

  function renderRunProgress(project) {
    const container = state.elements.runProgress;
    if (!container) return;

    const labels = ['Configured', 'Starting', 'Ready', 'Previewing'];
    const index = runProgressIndex(project);
    container.textContent = '';
    labels.forEach((label, stepIndex) => {
      const step = document.createElement('div');
      step.className = 'progress-step';
      if (index === stepIndex) {
        step.classList.add('active');
      } else if (index > stepIndex) {
        step.classList.add('done');
      }
      step.textContent = label;
      container.appendChild(step);
    });
  }

  function resetPreviewState() {
    state.previewVisible = false;
    state.previewProjectId = null;
    state.previewUrl = '';
    state.previewStatus = 'idle';
  }

  function previewBounds() {
    const viewport = state.elements.previewViewport;
    if (!viewport || state.elements.previewPanel.hidden) {
      return null;
    }

    const rect = viewport.getBoundingClientRect();
    return {
      x: Math.round(rect.x),
      y: Math.round(rect.y),
      width: Math.round(rect.width),
      height: Math.round(rect.height),
    };
  }

  async function syncPreviewBounds() {
    if (!state.previewVisible || !state.api?.resizeProjectPreview) {
      return;
    }

    const bounds = previewBounds();
    if (!bounds || bounds.width < 120 || bounds.height < 80) {
      return;
    }

    await state.api.resizeProjectPreview(bounds);
  }

  function renderPreview(project) {
    const visible = Boolean(state.previewVisible && project && !project.isDraft);
    state.elements.previewPanel.hidden = !visible;

    if (!visible) {
      return;
    }

    state.elements.previewUrlLabel.textContent =
      state.previewUrl || project.url || getAutoUrl(project.port);
    state.elements.previewPlaceholder.textContent =
      state.previewStatus === 'failed' ? 'Preview failed.' : 'Loading...';
    state.elements.previewPlaceholder.hidden = state.previewStatus === 'ready';
    state.elements.reloadPreviewBtn.disabled = !state.previewVisible;
    state.elements.openPreviewExternalBtn.disabled = !state.previewVisible;
    state.elements.closePreviewBtn.disabled = !state.previewVisible;

    window.requestAnimationFrame(() => {
      syncPreviewBounds().catch(showError);
    });
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
    const stopping = project?.runtime?.status === 'stopping';

    state.elements.saveProjectBtn.disabled = !project || !valid;
    state.elements.saveAndStartBtn.disabled = !project || !valid || active || stopping;
    state.elements.deleteProjectBtn.disabled = !saved;
    state.elements.startProjectBtn.disabled = !saved || !valid || dirty || active;
    state.elements.stopProjectBtn.disabled =
      !saved || !active || project.runtime.status === 'stopping';
    state.elements.restartProjectBtn.disabled =
      !saved || !valid || dirty || project.runtime.status === 'stopping';
    state.elements.openProjectBtn.disabled = !saved || !ready;
    state.elements.previewProjectBtn.disabled = !saved || !ready;
    state.elements.copyLogsBtn.disabled = !saved;
    state.elements.clearLogsBtn.disabled = !saved;
    state.elements.revealCommandBtn.disabled = !project;
    if (state.elements.doctorPanel) {
      renderDoctor(project);
    }
    renderRunProgress(project);
    updateWorkspaceActions();
    updateStatusRight();
  }

  function updateWorkspaceActions() {
    const active = activeProjects();
    const hasProjects = state.projects.length > 0;
    const profiles = state.workspace.savedWorkspaces || [];
    syncDefaultWorkspaceSelection();
    const resumable = hasResumableWorkspace();
    const startableCount = state.workspaceDiagnosis?.startableProjectIds?.length || 0;
    if (state.elements.workspaceSelect) {
      const previousValue = state.selectedWorkspaceId;
      state.elements.workspaceSelect.textContent = '';

      const lastOption = document.createElement('option');
      lastOption.value = '';
      lastOption.textContent = 'Last running workspace';
      state.elements.workspaceSelect.appendChild(lastOption);

      profiles.forEach((profile) => {
        const option = document.createElement('option');
        option.value = profile.id;
        option.textContent = `${profile.name} (${workspaceProjectCount(profile)})`;
        state.elements.workspaceSelect.appendChild(option);
      });

      if (profiles.some((profile) => profile.id === previousValue)) {
        state.elements.workspaceSelect.value = previousValue;
      } else {
        state.selectedWorkspaceId = '';
        state.elements.workspaceSelect.value = '';
      }
      if (
        state.elements.workspaceNameInput &&
        document.activeElement !== state.elements.workspaceNameInput
      ) {
        state.elements.workspaceNameInput.value = selectedWorkspaceProfile()?.name || '';
      }
      state.elements.workspaceSelect.hidden = profiles.length <= 1;
      state.elements.workspaceSelect.disabled = active.length > 0 || profiles.length === 0;
    }
    if (state.elements.saveWorkspaceBtn) {
      state.elements.saveWorkspaceBtn.disabled =
        active.length === 0 && !(state.workspace.lastRunningProjectIds || []).length;
    }
    if (state.elements.exportWorkspaceBtn) {
      state.elements.exportWorkspaceBtn.disabled = !hasProjects;
    }
    if (state.elements.resumeWorkspaceBtn) {
      state.elements.resumeWorkspaceBtn.disabled = active.length > 0 || !resumable;
    }
    if (state.elements.startReadyWorkspaceBtn) {
      state.elements.startReadyWorkspaceBtn.disabled =
        active.length > 0 || !hasProjects || startableCount === 0;
    }
    if (state.elements.startAllProjectsBtn) {
      state.elements.startAllProjectsBtn.disabled = !hasProjects;
    }
    if (state.elements.stopAllProjectsBtn) {
      state.elements.stopAllProjectsBtn.disabled = active.length === 0;
    }
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

    resetPreviewState();
    closePreviewInMain();
    state.collapsedSections.setup = false;
    state.collapsedSections.doctor = false;
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

  async function importWorkspacePackFromDirectory() {
    if (!state.api?.inspectWorkspacePack || !state.api?.importWorkspacePack) {
      throw new Error('Workspace pack import is unavailable.');
    }

    const rootDir = await state.api.selectDirectory();
    if (!rootDir) return;

    setStatus('Reading workspace pack...');
    const summary = await state.api.inspectWorkspacePack(rootDir);
    const projectLines = summary.projects
      .slice(0, 5)
      .map((project) => `${project.name} - ${project.command}`)
      .join('\n');
    const moreProjects =
      summary.projects.length > 5 ? `\n...and ${summary.projects.length - 5} more` : '';
    const ok = window.confirm(
      `Import ${summary.name}?\n\n${summary.projects.length} project(s), ${
        summary.workspaces.length
      } workspace profile(s).\n\n${projectLines}${moreProjects}\n\nCommands will be saved but not started.`
    );
    if (!ok) return;

    resetPreviewState();
    closePreviewInMain();
    state.draft = null;
    state.validation = null;
    state.diagnosis = null;
    state.commandVisible = false;

    const result = await state.api.importWorkspacePack(rootDir);
    state.workspace = normalizeWorkspaceForView(result.workspace);
    state.selectedWorkspaceId =
      result.importedWorkspaceIds?.[0] || result.updatedWorkspaceIds?.[0] || '';
    state.selectedId = result.importedProjectIds?.[0] || result.updatedProjectIds?.[0] || null;
    await loadProjects(result.projects);
    setStatus(
      `Imported ${result.importedProjectIds.length} project(s), updated ${result.updatedProjectIds.length}.`
    );
  }

  async function exportWorkspacePackToDirectory() {
    if (!state.api?.exportWorkspacePack) {
      throw new Error('Workspace pack export is unavailable.');
    }

    const rootDir = await state.api.selectDirectory();
    if (!rootDir) return;

    setStatus('Writing workspace pack...');
    const result = await state.api.exportWorkspacePack(rootDir);
    const skipped = result.skippedProjects?.length || 0;
    const skippedText = skipped > 0 ? ` Skipped ${skipped} project(s) outside that folder.` : '';
    setStatus(
      `Exported ${result.projectCount} project(s) to ${result.packPath}.${skippedText}`,
      skipped > 0 ? 'error' : undefined
    );
  }

  async function createSampleProjectFromBundle() {
    if (!state.api.createSampleProject) {
      throw new Error('Sample project action is unavailable.');
    }

    const button = state.elements.emptySampleProjectBtn;
    if (button) {
      button.disabled = true;
    }

    try {
      setStatus('Preparing sample project...');
      resetPreviewState();
      closePreviewInMain();
      state.draft = null;
      state.validation = null;
      state.diagnosis = null;
      state.commandVisible = false;

      const sample = await state.api.createSampleProject();
      await loadProjects();
      setSelected(sample.id);
      await validateCurrentDraft({ silent: true });
      setStatus('Sample project ready. Click Save & Start.');
    } finally {
      if (button) {
        button.disabled = false;
      }
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

  async function saveAndStartProject() {
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
      await state.api.startProject(saved.id);
      setStatus(`Started ${saved.name}. Waiting for readiness.`);
    } catch (error) {
      showError(error);
    }
  }

  async function deleteProject() {
    const project = selectedProject();
    if (!project || project.isDraft) return;
    if (!window.confirm(`Delete ${project.name}?`)) return;

    try {
      resetPreviewState();
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
      stopProject: 'Stopped',
      restartProject: 'Restarted',
      openProject: 'Opened',
    };

    try {
      if (actionName === 'stopProject' || actionName === 'restartProject') {
        resetPreviewState();
      }
      await state.api[actionName](project.id);
      setStatus(`${labels[actionName]} ${project.name}.`);
    } catch (error) {
      showError(error);
    }
  }

  async function runWorkspaceAction(actionName) {
    const labels = {
      resumeWorkspace: 'Resuming workspace.',
      startReadyWorkspace: 'Starting ready projects.',
      startAllProjects: 'Starting all projects.',
      stopAllProjects: 'Stopping all projects.',
    };

    try {
      setStatus(labels[actionName] || 'Updating workspace.');
      const result =
        actionName === 'resumeWorkspace'
          ? await state.api.resumeWorkspace(state.selectedWorkspaceId || null)
          : actionName === 'startReadyWorkspace'
            ? await state.api.startReadyWorkspace(state.selectedWorkspaceId || null)
            : await state.api[actionName]();
      if (result?.workspace) {
        state.workspace = result.workspace;
      }
      if (result?.diagnosis) {
        state.workspaceDiagnosis = normalizeWorkspaceDiagnosisForView(result.diagnosis);
      }
      if (result?.projects) {
        await loadProjects(result.projects);
      } else {
        await loadProjects();
      }

      const failed = (result?.results || []).filter((item) => item.status === 'failed');
      if (failed.length > 0) {
        setStatus(`Workspace updated with ${failed.length} project(s) needing attention.`, 'error');
      } else if (actionName === 'startReadyWorkspace' && result?.skippedBlockedProjectIds?.length) {
        setStatus(
          `Started ready projects. Skipped ${result.skippedBlockedProjectIds.length} blocked project(s).`
        );
      } else {
        setStatus(labels[actionName] || 'Workspace updated.');
      }
    } catch (error) {
      showError(error);
    }
  }

  async function saveWorkspaceProfile() {
    if (!state.api?.saveWorkspaceProfile) {
      throw new Error('Named workspaces are unavailable.');
    }

    const activeIds = activeProjects().map((project) => project.id);
    const fallbackIds = state.workspace.lastRunningProjectIds || [];
    const projectIds = activeIds.length > 0 ? activeIds : fallbackIds;
    if (projectIds.length === 0) {
      setStatus('Start projects before saving a workspace.', 'error');
      return;
    }

    const defaultName =
      selectedWorkspaceProfile()?.name ||
      projectIds
        .map((projectId) => state.projects.find((project) => project.id === projectId)?.name)
        .filter(Boolean)
        .slice(0, 2)
        .join(' + ') ||
      'Workspace';
    const name = state.elements.workspaceNameInput.value.trim() || defaultName;

    const result = await state.api.saveWorkspaceProfile({
      id: state.selectedWorkspaceId || undefined,
      name,
      projectIds,
    });
    state.workspace = normalizeWorkspaceForView(result.workspace);
    state.selectedWorkspaceId = result.profile.id;
    state.elements.workspaceNameInput.value = result.profile.name;
    await loadProjects();
    setStatus(`Saved workspace ${result.profile.name}.`);
  }

  async function refreshWorkspaceDoctor() {
    setStatus('Checking workspace.');
    await loadWorkspaceDiagnosis({ rerender: true });
    setStatus(state.workspaceDiagnosis.summary);
  }

  function closePreviewInMain() {
    if (state.api?.closeProjectPreview) {
      state.api.closeProjectPreview().catch(showError);
    }
  }

  async function openPreview() {
    const project = selectedProject();
    if (!project || project.isDraft) return;

    const validation = await validateCurrentDraft({ silent: true });
    if (!validation.valid) {
      setStatus('Fix project details before previewing.', 'error');
      return;
    }

    if (isFormDirty()) {
      setStatus('Save changes before previewing.', 'error');
      return;
    }

    if (project.runtime?.status !== 'ready') {
      setStatus('Preview is available when the project is ready.', 'error');
      return;
    }

    state.previewVisible = true;
    state.previewProjectId = project.id;
    state.previewUrl = project.url;
    state.previewStatus = 'loading';
    state.collapsedSections.setup = true;
    state.collapsedSections.doctor = true;
    renderRuntime(project);
    renderSetup(project);

    await new Promise((resolve) => window.requestAnimationFrame(resolve));

    const bounds = previewBounds();
    if (!bounds) {
      resetPreviewState();
      renderRuntime(project);
      setStatus('Preview area is unavailable.', 'error');
      return;
    }

    try {
      await state.api.previewProject(project.id, bounds);
      setStatus(`Previewing ${project.name}.`);
    } catch (error) {
      resetPreviewState();
      renderRuntime(project);
      showError(error);
    }
  }

  async function closePreview({ silent = false } = {}) {
    const wasVisible = state.previewVisible;
    resetPreviewState();
    renderRuntime(selectedProject() || createDefaultDraft());

    if (state.api?.closeProjectPreview) {
      await state.api.closeProjectPreview();
    }

    if (wasVisible && !silent) {
      setStatus('Closed preview.');
    }
  }

  async function reloadPreview() {
    if (!state.previewVisible || !state.api?.reloadProjectPreview) {
      return;
    }

    state.previewStatus = 'loading';
    renderPreview(selectedProject());
    await state.api.reloadProjectPreview();
    setStatus('Reloaded preview.');
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
    if (actionId === DOCTOR_ACTION.SYNC_URL_TO_PORT) {
      state.elements.urlInput.value = getAutoUrl(Number(state.elements.portInput.value));
      handleFormChange();
      setStatus('Synced URL to the selected port.');
      return;
    }

    if (actionId === DOCTOR_ACTION.USE_FREE_PORT) {
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

    if (actionId === DOCTOR_ACTION.REVEAL_COMMAND) {
      toggleCommandReveal();
      return;
    }

    if (project.isDraft) {
      await applyDraftDoctorAction(actionId);
      return;
    }

    if (actionId === DOCTOR_ACTION.COPY_REPORT) {
      const result = await state.api.copyDoctorReport(project.id);
      setStatus(`Copied Doctor report (${result.lines} line(s)).`);
      return;
    }

    if (actionId === DOCTOR_ACTION.REVEAL_DIRECTORY) {
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
    renderSetup(selectedProject());
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
    state.elements.importWorkspaceBtn.addEventListener('click', () =>
      importWorkspacePackFromDirectory().catch(showError)
    );
    state.elements.emptyAddProjectBtn.addEventListener('click', () =>
      importProjectFromDirectory().catch(showError)
    );
    state.elements.emptyImportWorkspaceBtn.addEventListener('click', () =>
      importWorkspacePackFromDirectory().catch(showError)
    );
    state.elements.emptySampleProjectBtn.addEventListener('click', () =>
      createSampleProjectFromBundle().catch(showError)
    );
    state.elements.saveProjectBtn.addEventListener('click', saveProject);
    state.elements.saveAndStartBtn.addEventListener('click', () =>
      saveAndStartProject().catch(showError)
    );
    state.elements.deleteProjectBtn.addEventListener('click', deleteProject);
    state.elements.resumeWorkspaceBtn.addEventListener('click', () =>
      runWorkspaceAction('resumeWorkspace').catch(showError)
    );
    state.elements.startReadyWorkspaceBtn.addEventListener('click', () =>
      runWorkspaceAction('startReadyWorkspace').catch(showError)
    );
    state.elements.saveWorkspaceBtn.addEventListener('click', () =>
      saveWorkspaceProfile().catch(showError)
    );
    state.elements.exportWorkspaceBtn.addEventListener('click', () =>
      exportWorkspacePackToDirectory().catch(showError)
    );
    state.elements.workspaceSelect.addEventListener('change', () => {
      state.selectedWorkspaceId = state.elements.workspaceSelect.value;
      state.elements.workspaceNameInput.value = selectedWorkspaceProfile()?.name || '';
      loadWorkspaceDiagnosis({ rerender: true }).catch(showError);
    });
    state.elements.startAllProjectsBtn.addEventListener('click', () =>
      runWorkspaceAction('startAllProjects').catch(showError)
    );
    state.elements.stopAllProjectsBtn.addEventListener('click', () =>
      runWorkspaceAction('stopAllProjects').catch(showError)
    );
    state.elements.refreshBtn.addEventListener('click', () => loadProjects().catch(showError));
    state.elements.refreshWorkspaceDoctorBtn.addEventListener('click', () =>
      refreshWorkspaceDoctor().catch(showError)
    );
    state.elements.toggleSetupBtn.addEventListener('click', () => toggleSection('setup'));
    state.elements.browseDirBtn.addEventListener('click', () => browseDirectory().catch(showError));
    state.elements.startProjectBtn.addEventListener('click', () =>
      runProjectAction('startProject')
    );
    state.elements.stopProjectBtn.addEventListener('click', () => runProjectAction('stopProject'));
    state.elements.restartProjectBtn.addEventListener('click', () =>
      runProjectAction('restartProject')
    );
    state.elements.openProjectBtn.addEventListener('click', () => runProjectAction('openProject'));
    state.elements.previewProjectBtn.addEventListener('click', () =>
      openPreview().catch(showError)
    );
    state.elements.reloadPreviewBtn.addEventListener('click', () =>
      reloadPreview().catch(showError)
    );
    state.elements.openPreviewExternalBtn.addEventListener('click', () =>
      runProjectAction('openProject')
    );
    state.elements.closePreviewBtn.addEventListener('click', () => closePreview().catch(showError));
    state.elements.clearLogsBtn.addEventListener('click', () => clearLogs().catch(showError));
    state.elements.copyLogsBtn.addEventListener('click', () => copyLogs().catch(showError));
    state.elements.revealCommandBtn.addEventListener('click', toggleCommandReveal);
    state.elements.copyDoctorReportBtn.addEventListener('click', () =>
      handleDoctorAction(DOCTOR_ACTION.COPY_REPORT).catch(showError)
    );
    state.elements.revealProjectDirBtn.addEventListener('click', () =>
      handleDoctorAction(DOCTOR_ACTION.REVEAL_DIRECTORY).catch(showError)
    );
    state.elements.toggleDoctorBtn.addEventListener('click', () => toggleSection('doctor'));
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
      'importWorkspaceBtn',
      'emptyAddProjectBtn',
      'emptyImportWorkspaceBtn',
      'emptySampleProjectBtn',
      'draftNotice',
      'runProgress',
      'saveProjectBtn',
      'saveAndStartBtn',
      'deleteProjectBtn',
      'resumeWorkspaceBtn',
      'startReadyWorkspaceBtn',
      'saveWorkspaceBtn',
      'exportWorkspaceBtn',
      'workspaceSelect',
      'workspaceNameInput',
      'workspaceDoctorPanel',
      'workspaceDoctorBadge',
      'workspaceDoctorSummary',
      'workspaceDoctorTarget',
      'workspaceDoctorTotals',
      'workspaceDoctorChecks',
      'workspaceDoctorProjects',
      'refreshWorkspaceDoctorBtn',
      'startAllProjectsBtn',
      'stopAllProjectsBtn',
      'refreshBtn',
      'setupPanel',
      'setupSummary',
      'setupFields',
      'toggleSetupBtn',
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
      'previewProjectBtn',
      'previewPanel',
      'previewUrlLabel',
      'previewViewport',
      'previewPlaceholder',
      'reloadPreviewBtn',
      'openPreviewExternalBtn',
      'closePreviewBtn',
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
      'toggleDoctorBtn',
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
        if (state.previewProjectId === event.projectId && event.state?.status !== 'ready') {
          resetPreviewState();
        }
        renderRuntime(project);
      }
    });

    if (state.api.onPreviewEvent) {
      state.api.onPreviewEvent((event) => {
        if (!state.previewVisible || event.projectId !== state.previewProjectId) {
          return;
        }

        state.previewStatus = event.status || state.previewStatus;
        if (event.url) {
          state.previewUrl = event.url;
        }
        renderPreview(selectedProject());

        if (event.status === 'failed') {
          setStatus(`Preview failed: ${event.message || 'Unable to load URL.'}`, 'error');
        }
      });
    }
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
    if (window.ResizeObserver && state.elements.previewViewport) {
      state.previewResizeObserver = new ResizeObserver(() => {
        syncPreviewBounds().catch(showError);
      });
      state.previewResizeObserver.observe(state.elements.previewViewport);
    }
    window.addEventListener('resize', () => {
      syncPreviewBounds().catch(showError);
    });
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
    runProgressIndex,
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
