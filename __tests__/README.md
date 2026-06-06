# LocalWrap Tests

This directory contains the test suite for LocalWrap, a secure desktop launcher for local development projects.

## Test Structure

- **`validation.test.js`** - Tests for local project URL validation.
- **`port-check.test.js`** - Tests for real port parsing, validation, availability, and selection.
- **`server-management.test.js`** - Tests for project process lifecycle behavior.
- **`project-inspection.test.js`** - Tests for first-run directory inspection and launch suggestions.
- **`project-validation.test.js`** - Tests for structured project draft validation.
- **`project-store.test.js`** - Tests for persisted project normalization and validation.
- **`renderer-view-model.test.js`** - Tests for renderer view-model helpers.
- **`renderer-ui.test.js`** - Tests for key first-run, validation, and log-control UI anchors.
- **`preload.test.js`** - Tests for the preload IPC surface.
- **`integration.test.js`** - Tests for script discovery and readiness helpers.

## Running Tests

### Run all tests

```bash
npm test
```

### Run tests in watch mode

```bash
npm run test:watch
```

### Run tests with coverage

```bash
npm run test:coverage
```

## Test Coverage

The tests cover:

- Local project URL validation.
- Port availability and selection.
- Directory inspection and package script suggestions.
- Structured draft validation errors and warnings.
- Project persistence and validation.
- Project process lifecycle events.
- Preload IPC exposure.
- Renderer view-model behavior.
- Package script discovery and readiness polling.

## Adding New Tests

When adding new functionality to LocalWrap, please add corresponding tests in this directory. Follow the existing naming convention: `*.test.js`.

## Test Configuration

Tests are configured in:

- `jest.config.js` - Jest configuration
- `jest.setup.js` - Test setup and mocks

The tests use mocks for Electron APIs to avoid requiring the full Electron runtime during testing.
