# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.2.0] - 2026-06-03

### Added

- In-app auto-update via `electron-updater`: checks on launch and via a tray
  "Check for Updates…" item. Works on Windows and Linux; silent macOS updates
  require code signing (planned follow-on).

### Changed

- macOS builds are now produced for both Intel (`x64`) and Apple Silicon
  (`arm64`), instead of arm64-only.

## [2.1.1] - 2026-06-03

### Changed

- Test integrity: `validateLocalhostURL` extracted to `lib/urlValidation.js` and
  imported by both `main.js` and its test (the tests previously re-declared copies
  of the code, so they passed even when the app was broken). The preload test now
  exercises the real `contextBridge` surface.
- Added ESLint + Prettier with a `lint`/`format` script; `lint` now runs in CI.
- Removed the unused `validator` dependency.

## [2.1.0] - 2026-06-02

### Added

- **Run a dev script** from the in-window panel: start/stop a command (e.g.
  `npm run dev`) with live streamed output and a working-directory picker.
  Privileged actions run over Electron IPC (never the localhost HTTP surface),
  restricted to a dev-tool allowlist (`npm`, `npx`, `yarn`, `pnpm`, `node`,
  `bun`, `python`, `python3`, `deno`), with shell metacharacters rejected and no
  shell used on macOS/Linux.

### Fixed

- The in-window control panel never ran in v2.0.0: the strict CSP
  (`script-src 'self'`, `script-src-attr 'none'`) blocked the inline `<script>`
  and `onclick=` handlers. Renderer JS now lives in `public/app.js`
  (same-origin, CSP-allowed) and all controls are wired via `addEventListener`.

## [2.0.0] - 2026-06-01

LocalWrap is now **free and open source**. This release relicenses the project,
modernizes the runtime, and ships prebuilt installers via GitHub Releases.

### Added

- CI release workflow: pushing a `v*` tag builds Windows/macOS/Linux installers on
  native runners and attaches them to a GitHub Release.
- Community files: `CONTRIBUTING.md`, `SECURITY.md`, an expanded `README.md`, and this
  changelog.

### Changed

- **Relicensed under the MIT License** (previously proprietary). No license keys,
  trials, or activation — just the app.
- Replaced the npm-publish workflow with the installer release workflow (a desktop
  app is distributed as installers, not an npm package).
- Upgraded Electron (32 → 42), electron-builder (25 → 26), and helmet (7 → 8); updated
  validator to the latest patched release. Resolves all known `npm audit` advisories.

### Fixed

- Hardened the server list rendering in the UI to build DOM nodes with `textContent`
  instead of injecting HTML, removing a potential XSS vector.

### Removed

- Dropped the unused `electron-test` dev dependency and a stale `server.js` entry from
  the build configuration.

## [1.0.1] - 2025-07-29

- Windows distribution release.

## [1.0.0] - 2025-07-29

- Initial release: multi‑server localhost management, system tray integration, and a
  secure Electron + Express foundation.
