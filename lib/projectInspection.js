'use strict';

const fs = require('fs');
const path = require('path');
const { discoverPackageScripts } = require('./packageScripts');
const { normalizeProjectPort } = require('./portUtils');

function readPackageJson(cwd, fsImpl = fs) {
  const packagePath = path.join(cwd, 'package.json');
  if (!fsImpl.existsSync(packagePath)) {
    return {
      packageJson: null,
      warnings: [
        {
          field: 'cwd',
          code: 'package-json-missing',
          message: 'No package.json found. You can still enter a command manually.',
        },
      ],
    };
  }

  try {
    return {
      packageJson: JSON.parse(fsImpl.readFileSync(packagePath, 'utf8')),
      warnings: [],
    };
  } catch (_error) {
    return {
      packageJson: null,
      warnings: [
        {
          field: 'cwd',
          code: 'package-json-invalid',
          message: 'package.json could not be read. Enter a command manually.',
        },
      ],
    };
  }
}

function inferProjectName(cwd, packageJson) {
  if (packageJson?.name && typeof packageJson.name === 'string') {
    return packageJson.name;
  }

  if (typeof cwd === 'string' && cwd.trim() !== '') {
    return path.basename(cwd);
  }

  return 'Untitled Project';
}

async function inspectProjectDirectory(cwd, options = {}) {
  const fsImpl = options.fsImpl || fs;
  const preferredPort = normalizeProjectPort(options.preferredPort || 3000);
  const findAvailablePort = options.findAvailablePort;
  const warnings = [];

  if (typeof cwd !== 'string' || cwd.trim() === '') {
    return {
      cwd: '',
      name: 'Untitled Project',
      scripts: [],
      recommendedCommand: 'npm run dev',
      suggestedPort: preferredPort,
      suggestedUrl: `http://localhost:${preferredPort}`,
      warnings: [
        {
          field: 'cwd',
          code: 'cwd-required',
          message: 'Choose a project directory.',
        },
      ],
    };
  }

  const normalizedCwd = cwd.trim();
  if (!fsImpl.existsSync(normalizedCwd) || !fsImpl.statSync(normalizedCwd).isDirectory()) {
    return {
      cwd: normalizedCwd,
      name: inferProjectName(normalizedCwd),
      scripts: [],
      recommendedCommand: 'npm run dev',
      suggestedPort: preferredPort,
      suggestedUrl: `http://localhost:${preferredPort}`,
      warnings: [
        {
          field: 'cwd',
          code: 'cwd-missing',
          message: 'Directory does not exist.',
        },
      ],
    };
  }

  const packageResult = readPackageJson(normalizedCwd, fsImpl);
  warnings.push(...packageResult.warnings);
  const scripts = discoverPackageScripts(normalizedCwd, fsImpl);
  const firstScript = scripts[0];
  const suggestedPort = findAvailablePort ? await findAvailablePort(preferredPort) : preferredPort;

  if (scripts.length === 0) {
    warnings.push({
      field: 'command',
      code: 'scripts-missing',
      message: 'No package scripts found. Enter the command you use to start this project.',
    });
  }

  return {
    cwd: normalizedCwd,
    name: inferProjectName(normalizedCwd, packageResult.packageJson),
    scripts,
    recommendedCommand: firstScript?.command || 'npm run dev',
    suggestedPort,
    suggestedUrl: `http://localhost:${suggestedPort}`,
    warnings,
  };
}

module.exports = {
  inferProjectName,
  inspectProjectDirectory,
  readPackageJson,
};
