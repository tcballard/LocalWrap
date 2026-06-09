# LocalWrap

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Node](https://img.shields.io/badge/node-%3E%3D18-brightgreen.svg)](https://nodejs.org)
[![Electron](https://img.shields.io/badge/electron-42-47848F.svg)](https://www.electronjs.org)

A secure desktop launcher for local development projects. LocalWrap gives you a
small, retro Windows-95-styled desktop app to save projects, run their dev
commands, stream logs, track readiness, and open the local app URL without
terminal juggling.

## Features

- **Saved project launcher** — keep project directory, command, port, URL,
  autostart, and open-on-ready preferences in one place.
- **Guided project import** — pick a repo and LocalWrap suggests the name,
  command, port, and URL from common package scripts.
- **Process control** — start/stop/restart dev commands with `PORT` injected and
  bounded live output.
- **Readiness tracking** — LocalWrap polls local `http`/`https` URLs and marks
  projects ready when they respond.
- **Inline validation** — see missing directories, unsafe commands, invalid URLs,
  and busy ports before saving or starting.
- **Project Doctor** — see preflight checks, start timeline, readiness diagnosis,
  safe fixes, and a copyable report when a project needs attention.
- **One-click open** — launch a ready local app in your browser.
- **System tray integration** — minimize to the tray and keep projects running in
  the background.
- **Secure by default** — privileged actions are IPC-only, commands are
  allowlisted, local URLs are validated, and Electron runs with context isolation
  and no Node integration in the renderer.
- **Cross‑platform** — Windows, macOS, and Linux.

## Download

Grab a prebuilt installer for your platform from the
[**Releases page**](https://github.com/tcballard/LocalWrap/releases):

| Platform | File                           |
| -------- | ------------------------------ |
| Windows  | `.exe` installer (NSIS)        |
| macOS    | `.dmg` (Intel + Apple Silicon) |
| Linux    | `.AppImage`                    |

LocalWrap checks for updates on launch (and via the tray's **Check for Updates…**).
Auto-update works on Windows and Linux today; signed macOS auto-update is planned.

> **Note:** the installers are not code‑signed yet, so Windows SmartScreen and
> macOS Gatekeeper will warn about an "unknown developer." On Windows choose
> _More info → Run anyway_; on macOS right‑click the app and choose _Open_ the
> first time.

## Requirements (to build/run from source)

- [Node.js](https://nodejs.org) 18 or newer
- npm 9 or newer

## Install from source

```bash
git clone https://github.com/tcballard/LocalWrap.git
cd LocalWrap
npm install
```

## Run

```bash
npm start          # launch the app
npm run dev        # launch with dev flag
```

## Demo Project

This repo includes a dependency-free sample app at
`examples/sample-project`. On first launch, when no projects are saved, choose
**Try Sample Project** to copy that app into LocalWrap's user data folder and
save it as a normal project. LocalWrap selects it but does not start it
automatically, so click **Start** to see Project Doctor, logs, readiness,
**Preview**, and **Open**.

When running from source, you can still use **Add Project** and import
`examples/sample-project` manually.

## Build distributables

Packaged with [electron-builder](https://www.electron.build):

```bash
npm run dist        # current platform, no publish
npm run dist:mac    # macOS .dmg
npm run dist:win    # Windows NSIS installer
npm run dist:linux  # Linux AppImage
```

Output is written to `dist/`.

## Test

```bash
npm test            # run the Jest suite
npm run test:watch  # watch mode
npm run test:coverage
```

## Security

LocalWrap is built defensively:

- The app UI is loaded from a local file with a strict Content-Security-Policy;
  there is no browser-accessible mutating localhost control API.
- Project launch, process control, directory picking, and URL opening are only
  reachable through Electron IPC exposed by the preload script.
- Dev commands are restricted to an allowlist (`npm`, `npx`, `yarn`, `pnpm`,
  `node`, `bun`, `python`, `python3`, `deno`) and shell metacharacters are
  rejected.
- Local project URLs are limited to `localhost`, `127.0.0.1`, and `::1` on
  ports 1000-65535.
- The Electron renderer runs with `contextIsolation` enabled and `nodeIntegration`
  disabled.

Found a vulnerability? Please see [SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Tom Ballard
