'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const { validateScriptCommand } = require('./scriptValidation');

/**
 * Spawn an allowlisted dev script and stream its output line-by-line.
 *
 * This is the Electron-free core of the `script:run` IPC handler so it can be
 * exercised by tests without a renderer. The caller supplies `onLine`/`onExit`
 * callbacks; the main process wires those to webContents.send.
 *
 * @param {object}   opts
 * @param {string}   opts.command   Raw user command, e.g. "npm run dev".
 * @param {string}  [opts.cwd]      Working directory (must exist).
 * @param {number}  [opts.port]     Port exposed to the child via env.PORT.
 * @param {(line:string)=>void} opts.onLine  Called per output line.
 * @param {(code:number|null)=>void} opts.onExit  Called once on close.
 * @returns {import('child_process').ChildProcess}
 * @throws {Error} if the command is not allowlisted or cwd is invalid.
 */
function startScript({ command, cwd, port, onLine, onExit }) {
  // Throws on disallowed command / shell metacharacters.
  const { command: cmd, args } = validateScriptCommand(command);

  if (cwd) {
    if (!fs.existsSync(cwd) || !fs.statSync(cwd).isDirectory()) {
      throw new Error(`Working directory does not exist: ${cwd}`);
    }
  }

  // Windows resolves npm/yarn/etc. via a shell; macOS/Linux never use one.
  const isWin = process.platform === 'win32';
  const child = spawn(cmd, args, {
    cwd: cwd || process.cwd(),
    env: { ...process.env, PORT: port != null ? String(port) : process.env.PORT },
    shell: isWin,
  });

  const handleChunk = (buf) => {
    buf.toString().split(/\r?\n/).forEach((line) => {
      if (line.length > 0 && typeof onLine === 'function') onLine(line);
    });
  };

  child.stdout.on('data', handleChunk);
  child.stderr.on('data', handleChunk);
  child.on('error', (err) => {
    if (typeof onLine === 'function') onLine(`[error] ${err.message}`);
  });
  child.on('close', (code) => {
    if (typeof onExit === 'function') onExit(code);
  });

  return child;
}

module.exports = { startScript };
