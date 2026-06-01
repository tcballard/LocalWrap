'use strict';

/**
 * Allowlist of dev-tool runners permitted as the first token of a script.
 * Anything else is rejected — LocalWrap never runs arbitrary binaries.
 */
const ALLOWED_COMMANDS = [
  'npm',
  'npx',
  'yarn',
  'pnpm',
  'node',
  'bun',
  'python',
  'python3',
  'deno',
];

// Shell metacharacters that could chain/redirect/expand commands. Even though
// scripts are spawned without a shell on macOS/Linux, we reject these as
// defense-in-depth (and because the Windows path may use a shell).
const SHELL_METACHARACTERS = /[;&|$`><(){}\[\]!#*?~\n\r]/;

/**
 * Validate and tokenize a user-supplied script string.
 *
 * @param {string} input e.g. "npm run dev"
 * @returns {{ command: string, args: string[] }}
 * @throws {Error} if empty, contains shell metacharacters, or the first token
 *                 is not in the allowlist.
 */
function validateScriptCommand(input) {
  if (typeof input !== 'string' || input.trim() === '') {
    throw new Error('No command provided.');
  }

  const script = input.trim();

  if (SHELL_METACHARACTERS.test(script)) {
    throw new Error('Command contains disallowed shell characters.');
  }

  const tokens = script.split(/\s+/);
  const command = tokens[0];
  const args = tokens.slice(1);

  if (!ALLOWED_COMMANDS.includes(command)) {
    throw new Error(
      `Command "${command}" is not allowed. Allowed commands: ${ALLOWED_COMMANDS.join(', ')}.`
    );
  }

  return { command, args };
}

module.exports = { validateScriptCommand, ALLOWED_COMMANDS };
