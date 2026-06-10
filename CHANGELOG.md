# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Saved projects can no longer be silently wiped by a corrupt or unreadable
  `projects.json`: reads now fail closed, saves are written atomically, and
  every successful save keeps a `projects.json.bak`. If the file is ever
  unreadable at launch, LocalWrap asks whether to restore the backup or start
  fresh (the unreadable file is preserved alongside, never deleted).

### Changed

- The app version shown in the UI is now sourced from the main process
  (`package.json`) instead of a hardcoded copy in the preload script.
- Command validation also rejects `%`, `^`, and quote characters, closing
  cmd.exe expansion/escaping tricks on the Windows (shell) spawn path.
- CI now runs the test suite on Windows and macOS in addition to Linux, so
  platform-specific process handling is exercised before release time.

### Removed

- Dead code: the unused `dir:current` IPC channel / `getCurrentDirectory`
  preload API, the inert `new-window` handler (the event was removed in
  Electron 22; `setWindowOpenHandler` already governs window opening), and the
  phantom `running` runtime status in the renderer (the lifecycle never emits
  it).

## [2.7.0] - 2026-06-08

### Added

- First-launch **Try Sample Project** action when no projects are saved. It
  copies the bundled sample into user data, saves it as a normal project, and
  selects it without auto-starting, previewing, or opening a browser.
- Packaged apps now bundle the dependency-free sample project as an Electron
  Builder extra resource.

## [2.6.0] - 2026-06-08

### Added

- In-app project preview for saved ready projects, using an embedded Electron
  browser surface that has no Node.js or LocalWrap preload access.

### Changed

- Denser project dashboard layout with collapsible Project Setup and Project
  Doctor sections so the in-app preview has more room.

## [2.5.1] - 2026-06-08

### Fixed

- Ad-hoc sign macOS app bundles in release builds so unsigned DMGs still contain
  a sealed `.app` bundle instead of triggering macOS "damaged app" dialogs.

## [2.5.0] - 2026-06-06

### Added

- Project Doctor panel above logs with compact checks for directory, command,
  dependencies, port, URL, process start, and readiness.
- Non-persisted diagnosis timeline and Doctor report copying for saved projects.
- Safe Doctor actions for finding a free port, syncing URL to port, revealing
  the project folder, and revealing the launch command.
- Dependency-free sample project under `examples/sample-project` for demos and
  manual LocalWrap smoke tests.

### Changed

- Project start now runs Doctor preflight first; validation errors block start,
  while warnings remain advisory.
- Runtime state now carries diagnosis details for ready, failed,
  running-but-unresponsive, stopped, and exited processes.

## [2.4.0] - 2026-06-06

### Added

- Guided project import: choose a directory first, then LocalWrap inspects
  package scripts and suggests a name, command, port, and local URL.
- Inline project draft validation with field-level errors and warnings for
  missing directories, invalid commands, invalid URLs, port mismatches, and busy
  ports.
- Clearer runtime states for ready, failed, and running-but-unresponsive
  projects.
- Log controls for clearing, copying, and revealing the command attached to the
  selected project.
- More useful tray actions, including stop-all and per-running-project controls.

### Changed

- Reworked the first-run empty state around a single Add Project action.
- `Start` and `Save` now stay disabled until project details are valid; `Open` is
  strongest only when a project is ready.

## [2.3.0] - 2026-06-05

### Added

- Project launcher workflow: save local projects with directory, command, port,
  app URL, autostart, and open-on-ready preferences.
- IPC-only project actions for create/update/delete/start/stop/restart/open,
  with live bounded logs and readiness tracking.
- Package script discovery for selected project directories, preferring common
  scripts like `dev`, `start`, `preview`, and `serve`.

### Changed

- The Electron UI now loads from `public/app.html` with a CSP meta tag instead
  of being served by a localhost Express control server.
- Replaced the server-control panel with a project dashboard and per-project log
  view.
- Refactored core behavior into importable modules for project storage, process
  lifecycle, port checks, readiness polling, URL validation, and script discovery.
- CI now checks Prettier formatting, and Jest is configured to avoid Watchman.

### Removed

- Removed the browser-accessible mutating localhost server-management API and the
  no-longer-needed Express/Helmet/rate-limit runtime dependencies.

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
