# LocalWrap Sample Project

This is a tiny dependency-free local app for testing and demoing LocalWrap.

## Use It In LocalWrap

1. Start LocalWrap with `npm start` from the repository root.
2. Choose **Add Project**.
3. Select this folder: `examples/sample-project`.
4. Keep the suggested command, usually `npm run dev`.
5. Save, start, and open the project.

The app reads the `PORT` environment variable that LocalWrap injects. It also
responds at `/health` and `/api/status`, which makes it useful for readiness and
log demos.

## Run It Directly

```bash
npm run dev
```

Then open `http://localhost:3000`.
