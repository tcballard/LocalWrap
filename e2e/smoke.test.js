'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, expect, _electron: electron } = require('@playwright/test');

// The one journey that exercises every layer end to end: first launch with an
// empty config, create the bundled sample project, start it, watch readiness
// turn Ready, stop it, and exit cleanly.
test('first run: sample project starts, becomes ready, and stops', async () => {
  // Isolated config dir so the test never touches a real installation.
  const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'localwrap-e2e-'));
  const app = await electron.launch({
    args: ['.', '--no-sandbox'], // CI containers may run as root, without the Chromium sandbox
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, LOCALWRAP_USER_DATA: userData },
  });

  try {
    const window = await app.firstWindow();

    // First run shows the empty state with the sample action.
    const sampleButton = window.locator('#emptySampleProjectBtn');
    await expect(sampleButton).toBeVisible();
    await sampleButton.click();

    // The sample is saved and selected, but not auto-started.
    await expect(window.locator('#projectDetail')).toBeVisible();
    await expect(window.locator('#statusBadge')).toHaveText('Stopped');

    const startButton = window.locator('#startProjectBtn');
    await expect(startButton).toBeEnabled();
    await startButton.click();

    // Process spawn + readiness polling against the real sample server.
    await expect(window.locator('#statusBadge')).toHaveText('Ready', { timeout: 45_000 });
    await expect(window.locator('#terminal')).toContainText('[ready]');

    const stopButton = window.locator('#stopProjectBtn');
    await expect(stopButton).toBeEnabled();
    await stopButton.click();

    await expect(window.locator('#statusBadge')).toHaveText('Stopped', { timeout: 15_000 });
  } finally {
    await app.close();
    fs.rmSync(userData, { recursive: true, force: true });
  }
});
