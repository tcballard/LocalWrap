# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Relicensed the project under the MIT License (previously proprietary).
- Upgraded Electron (32 → 42), electron-builder (25 → 26), and helmet (7 → 8); updated
  validator to the latest patched release. Resolves all known `npm audit` advisories.

### Fixed

- Hardened the server list rendering in the UI to build DOM nodes with `textContent`
  instead of injecting HTML, removing a potential XSS vector.

### Removed

- Dropped the unused `electron-test` dev dependency and a stale `server.js` entry from
  the build configuration.

## [1.0.0]

- Initial release: multi‑server localhost management, system tray integration, and a
  secure Electron + Express foundation.
