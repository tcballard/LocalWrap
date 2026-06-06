const path = require('path');
const { startScript } = require('../lib/scriptRunner');

describe('startScript (integration)', () => {
  test('runs an allowlisted command and streams output + exit code', (done) => {
    const lines = [];
    startScript({
      command: 'node --version',
      onLine: (line) => lines.push(line),
      onExit: (code) => {
        try {
          expect(code).toBe(0);
          // node --version prints something like "v20.11.1"
          expect(lines.join('\n')).toMatch(/v?\d+\.\d+\.\d+/);
          done();
        } catch (err) {
          done(err);
        }
      },
    });
  }, 15000);

  test('throws on a non-existent working directory', () => {
    expect(() =>
      startScript({
        command: 'node --version',
        cwd: path.join(__dirname, 'definitely-does-not-exist-xyz'),
        onLine: () => {},
        onExit: () => {},
      })
    ).toThrow(/does not exist/);
  });

  test('throws on a disallowed command before spawning', () => {
    expect(() => startScript({ command: 'rm -rf /', onLine: () => {}, onExit: () => {} })).toThrow(
      /not allowed/
    );
  });
});
