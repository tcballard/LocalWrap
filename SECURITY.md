# Security Policy

## Supported versions

LocalWrap is actively maintained on the `main` branch. Fixes are released against the
latest version.

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities.

Instead, report privately using GitHub's
[private vulnerability reporting](https://github.com/tcballard/LocalWrap/security/advisories/new),
or email the maintainer directly.

When reporting, please include:

- A description of the vulnerability and its impact.
- Steps to reproduce (proof of concept if possible).
- The version / commit and your OS, Node, and Electron versions.

You can expect an initial acknowledgement within a few days. We'll keep you updated as
we investigate and will credit you in the release notes unless you prefer to remain
anonymous.

## Scope

LocalWrap runs a local control server and an Electron desktop shell. Areas of
particular interest:

- Bypasses of port/URL input validation.
- Renderer escapes (`contextIsolation` / preload boundary).
- CSP or rate‑limit bypasses on the local API.
