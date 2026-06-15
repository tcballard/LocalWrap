module.exports = {
  testEnvironment: 'node',
  watchman: false,
  testMatch: ['**/__tests__/**/*.js', '**/?(*.)+(spec|test).js'],
  // e2e/ belongs to Playwright (npm run test:e2e), not Jest.
  testPathIgnorePatterns: ['/node_modules/', '/e2e/'],
  collectCoverageFrom: [
    'main.js',
    'preload.js',
    'lib/**/*.js',
    'public/app.js',
    '!node_modules/**',
    '!dist/**',
  ],
  coverageDirectory: 'coverage',
  coverageReporters: ['text', 'lcov', 'html'],
  setupFilesAfterEnv: ['<rootDir>/jest.setup.js'],
};
