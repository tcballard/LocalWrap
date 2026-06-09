# LocalWrap Sample Project

This is a tiny dependency-free local app for testing and demoing LocalWrap.

## Use It In LocalWrap

1. Start LocalWrap with `npm start` from the repository root.
2. If no projects are saved, choose **Try Sample Project**. LocalWrap copies this
   app into its user data folder, saves it, and selects it.
3. Click **Start**, then use **Preview** or **Open** once it is ready.

You can also choose **Add Project**, select this folder, keep the suggested
command (`npm run dev`), save, start, and open the project.

The app reads the `PORT` environment variable that LocalWrap injects. It also
responds at `/health` and `/api/status`, which makes it useful for readiness and
log demos.

## Run It Directly

```bash
npm run dev
```

Then open `http://localhost:3000`.
