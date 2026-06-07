'use strict';

const fs = require('fs');
const path = require('path');

const PREFERRED_SCRIPT_ORDER = ['dev', 'start', 'preview', 'serve'];

function toScriptCommand(scriptName) {
  return scriptName === 'start' ? 'npm start' : `npm run ${scriptName}`;
}

function orderScriptNames(names) {
  const preferred = PREFERRED_SCRIPT_ORDER.filter((name) => names.includes(name));
  const rest = names
    .filter((name) => !PREFERRED_SCRIPT_ORDER.includes(name))
    .sort((a, b) => a.localeCompare(b));

  return [...preferred, ...rest];
}

function discoverPackageScripts(cwd, fsImpl = fs) {
  if (typeof cwd !== 'string' || cwd.trim() === '') {
    return [];
  }

  const packagePath = path.join(cwd, 'package.json');
  if (!fsImpl.existsSync(packagePath)) {
    return [];
  }

  let parsed;
  try {
    parsed = JSON.parse(fsImpl.readFileSync(packagePath, 'utf8'));
  } catch (_error) {
    return [];
  }

  const scripts = parsed && typeof parsed.scripts === 'object' ? parsed.scripts : {};
  return orderScriptNames(Object.keys(scripts)).map((name) => ({
    name,
    command: toScriptCommand(name),
    script: scripts[name],
    preferred: PREFERRED_SCRIPT_ORDER.includes(name),
  }));
}

module.exports = {
  PREFERRED_SCRIPT_ORDER,
  discoverPackageScripts,
  orderScriptNames,
  toScriptCommand,
};
