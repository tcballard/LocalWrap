'use strict';

const { defineConfig } = require('@playwright/test');

// End-to-end smoke tests drive the real Electron app (no browser downloads
// needed); unit tests stay in Jest. Run with: npm run test:e2e
module.exports = defineConfig({
  testDir: './e2e',
  timeout: 90_000,
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  reporter: [['list']],
});
