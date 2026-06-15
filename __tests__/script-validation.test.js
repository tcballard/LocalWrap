const { validateScriptCommand, ALLOWED_COMMANDS } = require('../lib/scriptValidation');

describe('validateScriptCommand', () => {
  test('accepts allowlisted dev commands and tokenizes them', () => {
    expect(validateScriptCommand('npm start')).toEqual({
      command: 'npm',
      args: ['start'],
    });
    expect(validateScriptCommand('npm run dev')).toEqual({
      command: 'npm',
      args: ['run', 'dev'],
    });
    expect(validateScriptCommand('node server.js')).toEqual({
      command: 'node',
      args: ['server.js'],
    });
    expect(validateScriptCommand('  yarn   dev  ')).toEqual({
      command: 'yarn',
      args: ['dev'],
    });
  });

  test('accepts every command in the allowlist', () => {
    for (const cmd of ALLOWED_COMMANDS) {
      expect(validateScriptCommand(`${cmd} --version`).command).toBe(cmd);
    }
  });

  test('rejects non-allowlisted binaries', () => {
    expect(() => validateScriptCommand('rm -rf .')).toThrow(/not allowed/);
    expect(() => validateScriptCommand('bash script.sh')).toThrow(/not allowed/);
    expect(() => validateScriptCommand('curl http://evil')).toThrow(/not allowed/);
    expect(() => validateScriptCommand('/bin/sh')).toThrow(/not allowed/);
  });

  test('rejects shell metacharacter injection', () => {
    expect(() => validateScriptCommand('npm start; rm -rf ~')).toThrow(/shell characters/);
    expect(() => validateScriptCommand('npm start && curl evil')).toThrow(/shell characters/);
    expect(() => validateScriptCommand('npm start | sh')).toThrow(/shell characters/);
    expect(() => validateScriptCommand('node $(whoami)')).toThrow(/shell characters/);
    expect(() => validateScriptCommand('npm start > /etc/passwd')).toThrow(/shell characters/);
    expect(() => validateScriptCommand('npm `whoami`')).toThrow(/shell characters/);
  });

  test('rejects cmd.exe expansion, escaping, and quoting', () => {
    expect(() => validateScriptCommand('node %USERPROFILE%')).toThrow(/shell characters/);
    expect(() => validateScriptCommand('npm run dev ^&^& evil')).toThrow(/shell characters/);
    expect(() => validateScriptCommand('node "server.js"')).toThrow(/shell characters/);
    expect(() => validateScriptCommand("npm run 'dev'")).toThrow(/shell characters/);
  });

  test('rejects empty or non-string input', () => {
    expect(() => validateScriptCommand('')).toThrow(/No command/);
    expect(() => validateScriptCommand('   ')).toThrow(/No command/);
    expect(() => validateScriptCommand(null)).toThrow(/No command/);
    expect(() => validateScriptCommand(undefined)).toThrow(/No command/);
  });
});
