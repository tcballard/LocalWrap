'use strict';

const fs = require('fs');
const { isValidProjectPort, parsePort } = require('./portUtils');
const { validateScriptCommand } = require('./scriptValidation');
const { validateLocalProjectURL } = require('./urlValidation');

function addMessage(bucket, field, code, message) {
  bucket.push({ field, code, message });
}

function getUrlPort(url) {
  try {
    return parsePort(new URL(url).port);
  } catch (_error) {
    return NaN;
  }
}

async function validateProjectDraft(draft = {}, options = {}) {
  const fsImpl = options.fsImpl || fs;
  const checkPortAvailable = options.checkPortAvailable;
  const checkAvailability = options.checkAvailability !== false;
  const errors = [];
  const warnings = [];
  const normalized = {
    name: typeof draft.name === 'string' ? draft.name.trim() : '',
    cwd: typeof draft.cwd === 'string' ? draft.cwd.trim() : '',
    command: typeof draft.command === 'string' ? draft.command.trim() : '',
    port: parsePort(draft.port),
    url: typeof draft.url === 'string' ? draft.url.trim() : '',
    autostart: Boolean(draft.autostart),
    openOnReady: Boolean(draft.openOnReady),
  };

  if (!normalized.name) {
    addMessage(errors, 'name', 'name-required', 'Name is required.');
  }

  if (!normalized.cwd) {
    addMessage(errors, 'cwd', 'cwd-required', 'Directory is required.');
  } else if (!fsImpl.existsSync(normalized.cwd) || !fsImpl.statSync(normalized.cwd).isDirectory()) {
    addMessage(errors, 'cwd', 'cwd-missing', 'Directory does not exist.');
  }

  if (!normalized.command) {
    addMessage(errors, 'command', 'command-required', 'Command is required.');
  } else {
    try {
      validateScriptCommand(normalized.command);
    } catch (error) {
      addMessage(errors, 'command', 'command-invalid', error.message);
    }
  }

  if (!isValidProjectPort(normalized.port)) {
    addMessage(errors, 'port', 'port-invalid', 'Port must be between 1000 and 65535.');
  } else if (checkPortAvailable && checkAvailability) {
    const available = await checkPortAvailable(normalized.port);
    if (!available) {
      addMessage(warnings, 'port', 'port-busy', 'Port appears to be in use.');
    }
  }

  if (!normalized.url) {
    addMessage(errors, 'url', 'url-required', 'App URL is required.');
  } else if (!validateLocalProjectURL(normalized.url)) {
    addMessage(errors, 'url', 'url-invalid', 'URL must be local http(s) on an allowed port.');
  } else if (isValidProjectPort(normalized.port)) {
    const urlPort = getUrlPort(normalized.url);
    if (urlPort !== normalized.port) {
      addMessage(warnings, 'url', 'url-port-mismatch', 'URL port does not match the project port.');
    }
  }

  return {
    valid: errors.length === 0,
    errors,
    warnings,
    normalized,
  };
}

module.exports = {
  getUrlPort,
  validateProjectDraft,
};
