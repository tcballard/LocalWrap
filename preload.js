/**
 * LocalWrap preload script.
 *
 * Exposes a small, explicit API to the renderer via contextBridge. Project
 * launch, process control, filesystem selection, and external opening stay in
 * the Electron main process; the renderer can only request those actions over
 * the IPC channels below.
 */
const { contextBridge, ipcRenderer } = require('electron');

if (typeof window !== 'undefined') {
  delete window.require;
  delete window.exports;
  delete window.module;
}

function subscribe(channel, callback) {
  const listener = (_event, data) => callback(data);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

contextBridge.exposeInMainWorld('localwrapAPI', {
  // Sandboxed preloads can't require app files, so the version comes from the
  // main process (app.getVersion() reads package.json) instead of a copy here.
  version: ipcRenderer.sendSync('app:version'),
  platform: 'desktop',
  isElectron: true,

  listProjects: () => ipcRenderer.invoke('project:list'),
  inspectDirectory: (workingDir) => ipcRenderer.invoke('project:inspectDirectory', workingDir),
  validateProjectDraft: (draft) => ipcRenderer.invoke('project:validateDraft', draft),
  diagnoseProjectDraft: (draft) => ipcRenderer.invoke('project:diagnoseDraft', draft),
  createProject: (project) => ipcRenderer.invoke('project:create', project),
  createSampleProject: () => ipcRenderer.invoke('project:createSample'),
  updateProject: (projectId, patch) => ipcRenderer.invoke('project:update', projectId, patch),
  deleteProject: (projectId) => ipcRenderer.invoke('project:delete', projectId),
  startProject: (projectId) => ipcRenderer.invoke('project:start', projectId),
  stopProject: (projectId) => ipcRenderer.invoke('project:stop', projectId),
  restartProject: (projectId) => ipcRenderer.invoke('project:restart', projectId),
  openProject: (projectId) => ipcRenderer.invoke('project:open', projectId),
  previewProject: (projectId, bounds) => ipcRenderer.invoke('project:preview', projectId, bounds),
  resizeProjectPreview: (bounds) => ipcRenderer.invoke('project:previewResize', bounds),
  reloadProjectPreview: () => ipcRenderer.invoke('project:previewReload'),
  closeProjectPreview: () => ipcRenderer.invoke('project:previewClose'),
  discoverScripts: (workingDir) => ipcRenderer.invoke('project:discoverScripts', workingDir),
  suggestPort: (preferredPort) => ipcRenderer.invoke('project:suggestPort', preferredPort),
  checkProjectPort: (port) => ipcRenderer.invoke('project:checkPort', port),
  clearProjectLogs: (projectId) => ipcRenderer.invoke('project:clearLogs', projectId),
  copyProjectLogs: (projectId) => ipcRenderer.invoke('project:copyLogs', projectId),
  applyDoctorAction: (projectId, actionId) =>
    ipcRenderer.invoke('project:applyDoctorAction', projectId, actionId),
  copyDoctorReport: (projectId) => ipcRenderer.invoke('project:copyDoctorReport', projectId),
  revealProjectDirectory: (projectId) => ipcRenderer.invoke('project:revealDirectory', projectId),

  selectDirectory: () => ipcRenderer.invoke('dir:select'),

  onProjectEvent: (callback) => subscribe('project:event', callback),
  onProjectListChanged: (callback) => subscribe('project:list-changed', callback),
  onPreviewEvent: (callback) => subscribe('preview:event', callback),
});
