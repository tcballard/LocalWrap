# LocalWrap

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Node](https://img.shields.io/badge/node-%3E%3D18-brightgreen.svg)](https://nodejs.org)
[![Electron](https://img.shields.io/badge/electron-42-47848F.svg)](https://www.electronjs.org)

A secure desktop wrapper for localhost development servers. LocalWrap gives you a
small, retro Windows‑95‑styled desktop app to start, stop, and open multiple local
dev servers — no terminal juggling required.

## Features

- **Multi‑server management** — start/stop/restart servers on any port (1000–65535)
  from a single window.
- **One‑click open** — launch any running server in your browser.
- **System tray integration** — minimize to the tray and keep servers running in the
  background.
- **Secure by default** — Content‑Security‑Policy headers (Helmet), rate limiting,
  input validation, and Electron context isolation with no Node integration in the
  renderer.
- **Cross‑platform** — Windows, macOS, and Linux.

## Download

Grab a prebuilt installer for your platform from the
[**Releases page**](https://github.com/tcballard/LocalWrap/releases):

| Platform | File |
| --- | --- |
| Windows  | `.exe` installer (NSIS) |
| macOS    | `.dmg` |
| Linux    | `.AppImage` |

> **Note:** the installers are not code‑signed yet, so Windows SmartScreen and
> macOS Gatekeeper will warn about an "unknown developer." On Windows choose
> *More info → Run anyway*; on macOS right‑click the app and choose *Open* the
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

# launch bound to a specific default port
npm run start:3000
npm run start:8080
npm run dev:3001
```

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

- **Helmet** sets a strict Content‑Security‑Policy and other hardening headers.
- **express-rate-limit** caps requests (100 per 15 minutes) to the local control API.
- **validator** sanitizes and validates user‑supplied ports and URLs.
- The Electron renderer runs with `contextIsolation` enabled and `nodeIntegration`
  disabled; the preload script exposes no privileged IPC.

Found a vulnerability? Please see [SECURITY.md](SECURITY.md).

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Tom Ballard
