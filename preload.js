/**
 * LocalWrap Preload Script
 * Secure bridge between main and renderer processes
 * 
 * This script runs in the renderer process but has access to Node.js APIs.
 * It exposes only specific, safe APIs to the renderer through contextBridge.
 */

const { contextBridge, ipcRenderer } = require('electron');

// Security: Only expose specific, safe APIs to the renderer
contextBridge.exposeInMainWorld('localwrapAPI', {
  // App info
  getVersion: () => {
    return process.versions.electron;
  },
  
  getPlatform: () => {
    return process.platform;
  },
  
  // Safe navigation
  openExternal: (url) => {
    // Validate URL before sending to main process
    try {
      const urlObj = new URL(url);
      if (urlObj.protocol === 'http:' || urlObj.protocol === 'https:') {
        ipcRenderer.invoke('open-external', url);
      }
    } catch (error) {
      console.warn('Invalid URL provided to openExternal:', url);
    }
  },
  
  // Window controls
  minimizeToTray: () => {
    ipcRenderer.invoke('minimize-to-tray');
  },
  
  showWindow: () => {
    ipcRenderer.invoke('show-window');
  },
  
  // Development tools (only in dev mode)
  openDevTools: () => {
    if (process.env.NODE_ENV === 'development') {
      ipcRenderer.invoke('open-dev-tools');
    }
  },
  
  // Security: Expose only safe Node.js information
  node: {
    versions: process.versions,
    platform: process.platform,
    arch: process.arch
  }
});

// Security: Remove Node.js from window object in renderer
delete window.require;
delete window.exports;
delete window.module;

// Security: Prevent access to Node.js globals
Object.defineProperty(window, 'global', {
  get() {
    throw new Error('global is not defined');
  },
  configurable: false
});

Object.defineProperty(window, 'process', {
  get() {
    throw new Error('process is not defined');
  },
  configurable: false
});

// Security: Store original functions before they might be overridden
window.originalSetTimeout = window.setTimeout;
window.originalSetInterval = window.setInterval;
window.originalRequestAnimationFrame = window.requestAnimationFrame;

// Security: Enhanced console security
const originalConsole = { ...console };
window.console = {
  ...originalConsole,
  // Prevent eval-like functions
  constructor: undefined,
  __proto__: null
};

// Security: Prevent iframe and object creation that might bypass security
const originalCreateElement = document.createElement;
document.createElement = function(tagName) {
  const element = originalCreateElement.call(this, tagName);
  
  // Security: Restrict certain elements
  if (tagName.toLowerCase() === 'iframe') {
    element.sandbox = 'allow-same-origin';
  }
  
  if (tagName.toLowerCase() === 'object' || tagName.toLowerCase() === 'embed') {
    console.warn('LocalWrap: object/embed elements are restricted for security');
  }
  
  return element;
};

// Security: CSP violation reporting
document.addEventListener('securitypolicyviolation', (event) => {
  console.warn('LocalWrap CSP Violation:', {
    blockedURI: event.blockedURI,
    violatedDirective: event.violatedDirective,
    originalPolicy: event.originalPolicy
  });
});

// Security: Monitor for potential XSS attempts
let scriptExecutions = 0;
const MAX_SCRIPT_EXECUTIONS = 50;

const originalEval = window.eval;
window.eval = function() {
  console.warn('LocalWrap: eval() is disabled for security');
  throw new Error('eval is disabled in LocalWrap for security reasons');
};

const originalFunction = window.Function;
window.Function = function() {
  console.warn('LocalWrap: Function constructor is disabled for security');
  throw new Error('Function constructor is disabled in LocalWrap for security reasons');
};

// Security: Rate limit script execution
const originalScriptExecute = HTMLScriptElement.prototype.appendChild;
HTMLScriptElement.prototype.appendChild = function() {
  scriptExecutions++;
  if (scriptExecutions > MAX_SCRIPT_EXECUTIONS) {
    console.warn('LocalWrap: Too many script executions, possible security threat');
    return;
  }
  return originalScriptExecute.apply(this, arguments);
};

// Development: Only log in dev mode
if (process.env.NODE_ENV === 'development') {
  console.log('LocalWrap preload script loaded - Security features active');
}

// Cleanup on unload
window.addEventListener('beforeunload', () => {
  // Reset counters
  scriptExecutions = 0;
});
