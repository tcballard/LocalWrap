(function () {
  const ACTIVE_STATUSES = new Set(['starting', 'running', 'ready', 'stopping']);
  const AUTO_URL_RE = /^https?:\/\/(?:localhost|127\.0\.0\.1|\[::1\]):\d+$/;

  const state = {
    api: null,
    projects: [],
    selectedId: null,
    draft: null,
    scripts: [],
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
    const port = Number(overrides.port || 3000);
    return {
      id: null,
      isDraft: true,
      name: overrides.name || '',
      cwd: overrides.cwd || '',
      command: overrides.command || 'npm run dev',
      port,
      url: overrides.url || getAutoUrl(port),
      autostart: Boolean(overrides.autostart),
      openOnReady: overrides.openOnReady !== false,
      runtime: {
        status: 'stopped',
        pid: null,
        logs: [],
      },
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
      stopping: 'Stopping',
      stopped: 'Stopped',
      error: 'Error',
    };
    return labels[status] || 'Stopped';
  }

  function setStatus(message, type) {
    const statusBar = state.elements.statusBar;
    if (!statusBar) return;

    statusBar.textContent = message;
    statusBar.style.color = type === 'error' ? '#a22222' : '';
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

  function setSelected(projectId) {
    state.selectedId = projectId;
    state.draft = null;
    state.scripts = [];
    const project = selectedProject();
    if (project?.cwd) {
      discoverScripts(project.cwd);
    }
    render();
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
  }

  function render() {
    renderProjectList();
    renderDetail();
  }

  function renderProjectList() {
    const list = state.elements.projectList;
    list.textContent = '';

    if (state.projects.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'project-subtitle';
      empty.textContent = 'No saved projects';
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
    state.elements.deleteProjectBtn.disabled = !hasProject || project.isDraft;

    if (!hasProject) {
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
  }

  function renderRuntime(project) {
    const runtime = project.runtime || { status: 'stopped', logs: [] };
    const active = isProjectActive(project);
    const saved = !project.isDraft;

    state.elements.statusBadge.className = `badge ${runtime.status || 'stopped'}`;
    state.elements.statusBadge.textContent = statusLabel(runtime.status);
    state.elements.pidLabel.textContent = `PID: ${runtime.pid || '-'}`;
    state.elements.urlLabel.textContent = project.url || getAutoUrl(project.port);
    state.elements.startProjectBtn.disabled = !saved || active;
    state.elements.stopProjectBtn.disabled = !saved || !active || runtime.status === 'stopping';
    state.elements.restartProjectBtn.disabled = !saved;
    state.elements.openProjectBtn.disabled = !saved || !project.url;

    state.elements.terminal.textContent = '';
    const logs = runtime.logs && runtime.logs.length > 0 ? runtime.logs : ['No output yet.'];
    logs.forEach((line) => {
      const row = document.createElement('div');
      row.textContent = line;
      state.elements.terminal.appendChild(row);
    });
    state.elements.terminal.scrollTop = state.elements.terminal.scrollHeight;
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
      option.textContent = script.name;
      select.appendChild(option);
    });

    select.disabled = false;
    select.value = state.scripts.some((script) => script.command === command) ? command : '';
  }

  async function discoverScripts(cwd) {
    if (!cwd) {
      state.scripts = [];
      renderScripts();
      return;
    }

    try {
      state.scripts = await state.api.discoverScripts(cwd);
      const project = selectedProject();
      const firstScript = state.scripts[0];
      if (
        project?.isDraft &&
        firstScript &&
        (!project.command || project.command === 'npm run dev')
      ) {
        project.command = firstScript.command;
        renderDetail();
      } else {
        renderScripts();
      }
    } catch (error) {
      state.scripts = [];
      renderScripts();
      showError(error);
    }
  }

  function readFormProject() {
    const project = selectedProject() || createDefaultDraft();
    return {
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
      isDraft: project.isDraft,
      id: project.id,
    };
  }

  async function saveProject() {
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
      await loadProjects();
      setStatus(`Saved ${saved.name}`);
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
      await loadProjects();
      setStatus(`Deleted ${project.name}`);
    } catch (error) {
      showError(error);
    }
  }

  async function runProjectAction(actionName) {
    const project = selectedProject();
    if (!project || project.isDraft) return;
    const labels = {
      startProject: 'Started',
      stopProject: 'Stopping',
      restartProject: 'Restarted',
      openProject: 'Opened',
    };

    try {
      await state.api[actionName](project.id);
      setStatus(`${labels[actionName]} ${project.name}`);
    } catch (error) {
      showError(error);
    }
  }

  async function browseDirectory() {
    const cwd = await state.api.selectDirectory();
    if (!cwd) return;

    const project = selectedProject() || createDefaultDraft();
    if (project.isDraft) {
      project.cwd = cwd;
      if (!project.name) {
        project.name = pathBasename(cwd);
      }
      state.draft = project;
    } else {
      state.elements.cwdInput.value = cwd;
      if (!state.elements.nameInput.value) {
        state.elements.nameInput.value = pathBasename(cwd);
      }
    }

    state.elements.cwdInput.value = cwd;
    await discoverScripts(cwd);
    if (project.isDraft) {
      renderDetail();
    }
  }

  function newProject() {
    state.draft = createDefaultDraft();
    state.selectedId = null;
    state.scripts = [];
    render();

    state.api
      .suggestPort(3000)
      .then((port) => {
        if (!state.draft || state.draft.cwd || state.draft.port !== 3000) {
          return;
        }
        state.draft.port = port;
        state.draft.url = getAutoUrl(port);
        renderDetail();
      })
      .catch(() => {});
  }

  function handlePortInput() {
    const urlInput = state.elements.urlInput;
    const port = Number(state.elements.portInput.value);
    if (!urlInput.value || AUTO_URL_RE.test(urlInput.value)) {
      urlInput.value = getAutoUrl(port);
    }
  }

  function wireControls() {
    state.elements.newProjectBtn.addEventListener('click', newProject);
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
    state.elements.portInput.addEventListener('input', handlePortInput);
    state.elements.scriptSelect.addEventListener('change', () => {
      if (state.elements.scriptSelect.value) {
        state.elements.commandInput.value = state.elements.scriptSelect.value;
      }
    });
  }

  function collectElements() {
    [
      'projectList',
      'emptyState',
      'projectDetail',
      'newProjectBtn',
      'saveProjectBtn',
      'deleteProjectBtn',
      'refreshBtn',
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
      'statusBadge',
      'pidLabel',
      'urlLabel',
      'terminal',
      'statusBar',
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
    createDefaultDraft,
    getAutoUrl,
    isProjectActive,
    mergeProjectEvent,
    normalizeProjectForView,
    pathBasename,
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
