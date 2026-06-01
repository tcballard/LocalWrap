# Contributing to LocalWrap

Thanks for your interest in improving LocalWrap! Contributions of all kinds are
welcome — bug reports, fixes, features, and documentation.

## Development setup

```bash
git clone https://github.com/tcballard/LocalWrap.git
cd LocalWrap
npm install
npm start        # or: npm run dev
```

## Running tests

LocalWrap uses [Jest](https://jestjs.io). Please make sure the suite passes before
opening a pull request:

```bash
npm test
npm run test:coverage   # optional: check coverage
```

## Submitting changes

1. Fork the repository and create a branch off `main`
   (`git checkout -b fix/short-description`).
2. Make your change. Keep commits focused and write a clear commit message.
3. Add or update tests for any behavior you change.
4. Run `npm test` and `npm audit` and make sure both are clean.
5. Open a pull request describing **what** changed and **why**.

## Guidelines

- Match the existing code style — no new linters or formatters are required.
- Keep the security posture intact: don't disable `contextIsolation`, weaken the CSP,
  or remove input validation without discussion.
- For larger changes or new features, please open an issue first so we can align on
  the approach.

## Reporting bugs

Open an [issue](https://github.com/tcballard/LocalWrap/issues) with steps to
reproduce, your OS, and the Node/Electron versions. Security issues should follow
[SECURITY.md](SECURITY.md) instead.
