# LocalWrap Tests

This directory contains the test suite for LocalWrap, a secure desktop wrapper for localhost development servers.

## Test Structure

- **`validation.test.js`** - Tests for URL validation functionality
- **`port-check.test.js`** - Tests for port availability checking
- **`server-management.test.js`** - Tests for server management functions
- **`preload.test.js`** - Tests for preload script functionality
- **`integration.test.js`** - Integration tests for main application logic

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
- URL validation for localhost URLs
- Port availability checking
- Server status management
- Preload script security features
- Integration testing of main application logic

## Adding New Tests

When adding new functionality to LocalWrap, please add corresponding tests in this directory. Follow the existing naming convention: `*.test.js`.

## Test Configuration

Tests are configured in:
- `jest.config.js` - Jest configuration
- `jest.setup.js` - Test setup and mocks

The tests use mocks for Electron APIs to avoid requiring the full Electron runtime during testing. 