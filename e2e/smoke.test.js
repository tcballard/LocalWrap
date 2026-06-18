'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { test, expect, _electron: electron } = require('@playwright/test');

// The one journey that exercises every layer end to end: first launch with an
// empty config, create the bundled sample project, Save & Start, preview, save
// a named workspace, stop all, resume it, and exit cleanly.
test('first run: sample project previews and resumes as a named workspace', async () => {
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

    const saveAndStartButton = window.locator('#saveAndStartBtn');
    await expect(saveAndStartButton).toBeEnabled();
    await saveAndStartButton.click();

    // Process spawn + readiness polling against the real sample server.
    await expect(window.locator('#statusBadge')).toHaveText('Ready', { timeout: 45_000 });
    await expect(window.locator('#terminal')).toContainText('[ready]');

    const previewButton = window.locator('#previewProjectBtn');
    await expect(previewButton).toBeEnabled();
    await previewButton.click();
    await expect(window.locator('#previewPanel')).toBeVisible();
    await expect(window.locator('#statusBar')).toContainText('Previewing');
    await window.locator('#closePreviewBtn').click();

    const saveWorkspaceButton = window.locator('#saveWorkspaceBtn');
    await expect(saveWorkspaceButton).toBeEnabled();
    await window.locator('#workspaceNameInput').fill('Sample stack');
    await saveWorkspaceButton.click();
    await expect(window.locator('#statusBar')).toContainText('Saved workspace Sample stack');

    const stopAllButton = window.locator('#stopAllProjectsBtn');
    await expect(stopAllButton).toBeEnabled();
    await stopAllButton.click();
    await expect(window.locator('#statusBadge')).toHaveText('Stopped', { timeout: 15_000 });

    const resumeButton = window.locator('#resumeWorkspaceBtn');
    await expect(resumeButton).toBeEnabled();
    await resumeButton.click();
    await expect(window.locator('#statusBadge')).toHaveText('Ready', { timeout: 45_000 });
  } finally {
    await app.close();
    fs.rmSync(userData, { recursive: true, force: true });
  }
});
