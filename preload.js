/**
 * LocalWrap preload script.
 *
 * Exposes a small, explicit API to the renderer via contextBridge. This is the
 * ONLY place the privileged dev-script actions are reachable — a plain browser
 * hitting the localhost server never runs this preload, so window.localwrapAPI
 * (and its runScript capability) simply does not exist there.
 */
const { contextBridge, ipcRenderer } = require('electron');

// Basic security: remove dangerous globals. Guarded so the module can be
// required in a non-browser (test) environment.
if (typeof window !== 'undefined') {
  delete window.require;
  delete window.exports;
  delete window.module;
}

contextBridge.exposeInMainWorld('localwrapAPI', {
  version: '2.2.0',
  platform: 'desktop',
  isElectron: true,

  // --- Dev script execution (privileged, allowlisted in the main process) ---
  runScript: (options) => ipcRenderer.invoke('script:run', options),
  stopScript: (pid) => ipcRenderer.invoke('script:stop', pid),

  // Subscribe to streamed output; returns an unsubscribe function.
  onScriptOutput: (callback) => {
    const listener = (_event, data) => callback(data);
    ipcRenderer.on('script:output', listener);
    return () => ipcRenderer.removeListener('script:output', listener);
  },
  onScriptExit: (callback) => {
    const listener = (_event, data) => callback(data);
    ipcRenderer.on('script:exit', listener);
    return () => ipcRenderer.removeListener('script:exit', listener);
  },

  // --- Working directory ---
  selectDirectory: () => ipcRenderer.invoke('dir:select'),
  getCurrentDirectory: () => ipcRenderer.invoke('dir:current'),
});
