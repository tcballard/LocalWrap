# LocalWrap Technical Audit

_Audit date: 2026-06-10 · Audited at commit `5efd66a` (v2.7.0) · Scope: full source read (~6,700 LOC) — `main.js`, `preload.js`, all `lib/` modules, `public/app.js`/`app.html`, all configs and CI, representative test suites. Analysis only; no code was modified. Note: the Jest suite was assessed statically (dependencies were not installed in the audit environment), so "tests pass" claims are not re-verified here._

---

## Executive Summary

**Overall health grade: B+.** LocalWrap is a small, well-disciplined Electron desktop app whose security posture is genuinely above average for indie Electron projects — context isolation, sandboxing, strict CSP, IPC-only privileged surface, command allowlisting, and localhost-only URL validation are all real and verifiable in the code. The `lib/` layer is Electron-free, dependency-injected, and well tested. What keeps it from an A: (1) a **silent total-data-loss path** in `ProjectStore` where any read/parse failure of `projects.json` is swallowed and the next write erases every saved project; (2) **`main.js` — the entire privileged IPC/orchestration surface, 770 lines — has zero test coverage**, exactly the layer SECURITY.md declares most security-relevant; (3) **process stop has no SIGKILL escalation**, so a SIGTERM-ignoring dev server is reported "Stopped" while still running and holding its port. Top three opportunities: make persistence durable (atomic write + fail-closed read), extract `main.js` handlers into a testable module, and add a Windows/macOS CI test matrix to exercise the platform-specific process code that currently only runs at release time.

---

## Phase 1 — Repo Map

**Purpose:** "Secure desktop launcher for local development projects" — a Win95-styled Electron app that saves dev projects (directory + command + port + URL), starts/stops them with `PORT` injected, streams logs, polls readiness, embeds a preview, and diagnoses problems ("Project Doctor"). Solo-maintained, MIT, v2.7.0, released as installers via GitHub Releases with auto-update (Win/Linux). Maturity: a polished hobby/indie product — released to end users, versioned, changelogged — not a prototype, not an enterprise service.

**Stack:** Electron 42.3.3, plain CommonJS JavaScript (no TypeScript, no frontend framework), Jest 30, ESLint 10 flat config + Prettier, electron-builder 26, single runtime dependency (`electron-updater` 6.8.9). Node ≥18.

**Architecture (3 layers):**

```
public/app.html + app.js   ← renderer: vanilla-DOM UI, no Node access, talks only via window.localwrapAPI
        │ contextBridge (preload.js: ~28 invoke wrappers + 3 subscriptions)
main.js                    ← privileged: IPC handlers, window/tray/preview (BrowserView), autoupdate, doctor-action application
        │ plain requires
lib/ (13 modules)          ← Electron-free core: lifecycle, store, validation, doctor, readiness, ports, scripts
```

**Key directories:**

- `main.js` (770) — all IPC handlers, window/tray/preview wiring, update checks.
- `preload.js` (60) — narrow, explicit contextBridge API.
- `public/app.js` (1,369) — entire renderer in one IIFE; `app.html` (1,021) includes all CSS inline.
- `lib/` — `projectLifecycle.js` (524, process state machine), `projectDoctor.js` (448, diagnosis engine), `projectStore.js` (151, JSON persistence), plus validation/inspection/ports/readiness/sample helpers. Consistent DI pattern (`fsImpl`, `now`, `idFactory` injectable).
- `__tests__/` — 16 suites, mostly behavioral unit tests of `lib/`; has its own README.
- `.github/` — CI (lint+format+test+audit on ubuntu), Release (3-OS build matrix), Dependabot (weekly, grouped).
- `examples/sample-project/` — dependency-free demo server bundled as an extra resource.

**Conventions in use:** `'use strict'` CJS modules, options-object constructors with injected dependencies, structured `{field, code, message}` validation messages, errors thrown in main and surfaced via `showError` in the renderer, alphabetized exports. Recommendations below deliberately fit this style.

**Surprises:** (pleasant) the depth of security hardening and DI discipline for a solo project; (less pleasant) `main.js` is completely untested despite `jest.setup.js` containing a full Electron mock that was evidently built for that purpose, and the renderer "UI tests" assert against source-code strings rather than behavior.

---

## Phase 2 — Audit Report

Findings are grouped by dimension, sorted by severity. Each is labeled **[Fact]** (verifiable in code) or **[Judgment]** (interpretation).

### Architecture & design

**A1. `main.js` is a 770-line god file mixing every privileged concern — HIGH (enabler of the T1 testing gap)**
[Fact] Window management, tray menu construction, preview BrowserView lifecycle, all ~28 IPC handlers, doctor-action application, autoupdate, and app lifecycle live in one file (`main.js:1-770`) with module-level mutable globals (`mainWindow`, `tray`, `projectStore`, `projectLifecycle`, `previewView`, `previewProjectId`, `main.js:31-36`). [Judgment] Nothing here is untestable in principle — `registerIpcHandlers` (`main.js:511-672`) is mostly thin glue over `lib/` — but because handlers are registered as inline closures over those globals, none of the glue (e.g., `assertSafeProjectMutation`, `applyDoctorAction`, `previewProject` bounds logic) can be unit-tested, which is why it isn't (see T1). Consequence: regressions in the privileged surface ship undetected.

**A2. Renderer is a 1,369-line IIFE with manual DOM synchronization — MEDIUM**
[Fact] `public/app.js` holds all UI state in one mutable `state` object (`app.js:29-51`) and re-renders by imperatively rebuilding DOM (`render()` → `renderProjectList`/`renderDetail`/`renderDoctor`/`renderRuntime`, `app.js:336-527`). Only 9 pure helpers are exposed for testing (`app.js:1348-1358`). [Judgment] For the current feature set this is acceptable and fast; the cost is that ~90% of renderer logic (doctor actions, preview flow, validation sequencing with `validationSeq`, dirty-form logic) is untestable without a DOM harness. This is the file most likely to rot as features accrue.

**A3. Renderer re-implements `lib/` logic instead of sharing it — MEDIUM**
[Fact] Duplicated definitions that must be kept in sync by hand:

- Doctor check list: `app.js:11-19` vs `lib/projectDoctor.js:23-31`.
- Default diagnosis object: `app.js:83-97` vs `createDiagnosis` `lib/projectDoctor.js:79-89`.
- `ACTIVE_STATUSES`: `app.js:2-8` vs `lib/projectLifecycle.js:9` — **and they already disagree**: the renderer's set includes `'running'`, a status the lifecycle never emits (verified: lifecycle emits only `starting/ready/running-unresponsive/stopping/stopped/failed`).
- Draft doctor-action logic: `app.js:1059-1079` re-implements `getDoctorActionPatch` (`lib/projectDoctor.js:364-389`) including its own URL-sync regex `AUTO_URL_RE` (`app.js:9`).
- `getUrlPort` duplicated: `lib/projectValidation.js:12-18` and `lib/projectDoctor.js:219-225`; `readPackageJson` duplicated: `lib/projectInspection.js:8-40` and `lib/projectDoctor.js:155-170`.

Consequence: drift bugs of exactly the kind already present (`'running'`).

**A4. Deprecated `BrowserView` API — MEDIUM**
[Fact] The preview uses `BrowserView` (`main.js:3`, `main.js:146-154`, `setBrowserView` `main.js:222`). Electron deprecated `BrowserView` in favor of `WebContentsView` (Electron 30+). On Electron 42 it still works as a shim; [Judgment] a future Electron major (Dependabot updates these weekly) may remove it and break the preview feature.

### Code quality

**Q1. Dead code: `new-window` event handler can never fire — LOW**
[Fact] `main.js:755-762` registers `contents.on('new-window', …)`. The `new-window` event was removed from Electron in v22; on Electron 42 this listener is inert. Window-open is actually (and correctly) governed by `setWindowOpenHandler` (`main.js:156, 282`). Consequence: misleading "defense" that does nothing.

**Q2. Dead API surface: `dir:current` / `getCurrentDirectory` — LOW**
[Fact] Exposed at `main.js:671` and `preload.js:55`, never called anywhere in `public/app.js` (verified by grep). Unused privileged IPC channels are pure attack/maintenance surface.

**Q3. Partial log lines split across chunks — LOW**
[Fact] `lib/scriptRunner.js:42-49` splits every stdout/stderr chunk on newlines with no carry-over buffer, so a line spanning two chunks becomes two log entries. Consequence: garbled log lines in the UI and in Doctor reports; cosmetic but visible.

**Q4. Hand-rolled cancellation token alongside an unused AbortSignal implementation — LOW**
[Fact] `lib/readiness.js:59-79` fully supports `options.signal` (AbortSignal), but `ProjectLifecycle.watchReadiness` (`lib/projectLifecycle.js:427-433`) never passes one — it uses a parallel `readinessToken.cancelled` flag instead, so after stop, polling keeps probing the URL for up to 30s and only the result is discarded. Two cancellation mechanisms, one used, one half-used.

**Q5. Stale `onExit` from a previous run can write into a new run's state — LOW**
[Fact] `onExit` (`lib/projectLifecycle.js:172-203`) closes over the _old_ state object, but `this.appendLog(project.id, …)` (`:201`) resolves the project's _current_ state via the map. After a `restart()` where the old child exits late (after the 5s `waitForChildExit` timeout, `:52-65`), the old process's `[process exited with code …]` line is appended to the new run's logs. Edge case; confusing logs rather than corruption.

### Security

Overall: **strong**. The README's security claims (`README.md:107-121`) are accurate against the code — verified CSP (`public/app.html:6-7`: `default-src 'self'; connect-src 'none'; object-src 'none'…`), sandbox + contextIsolation + no nodeIntegration (`main.js:270-277`, `main.js:147-153`), allowlist + metacharacter rejection (`lib/scriptValidation.js:7-44`), localhost-only URLs (`lib/urlValidation.js:15-33`), IPC-only privileged actions, single-instance lock (`main.js:732`). No hardcoded secrets anywhere (verified). Remaining findings are hardening notes, not holes:

**S1. Windows `shell: true` path weakens the metacharacter defense — LOW-MEDIUM**
[Fact] On Windows, commands run through a shell (`lib/scriptRunner.js:34-40`), and the blocklist `lib/scriptValidation.js:12` omits `%` and `^` — so `cmd.exe` environment expansion (e.g. `%USERPROFILE%`) in arguments survives validation. [Judgment] Exploitability is low (commands originate from the local user via IPC, and the binary itself is still allowlisted), but it contradicts the stated "shell metacharacters are rejected" guarantee on exactly the platform that uses a shell. Cheap fix: add `%^"'` to the regex, or resolve the `.cmd` shims explicitly and drop `shell: true`.

**S2. Previewed page can open arbitrary external URLs in the user's browser with no prompt — LOW**
[Fact] In the preview BrowserView, any non-local `window.open`/navigation is forwarded to `shell.openExternal` (`main.js:140-143`, `main.js:156-164`). A malicious or compromised dev app being previewed can drive the default browser to arbitrary sites silently. [Judgment] Within this threat model (user previews their own dev server) this is acceptable, but a confirmation dialog for non-localhost targets would be cheap defense-in-depth.

**S3. All certificate errors auto-accepted for local URLs — LOW (informed trade-off)**
[Fact] `main.js:746-753` accepts any invalid cert when the URL passes `validateLocalProjectURL`; readiness probing also sets `rejectUnauthorized: false` (`lib/readiness.js:42`). [Judgment] Reasonable for self-signed local dev HTTPS; worth a code comment documenting the decision, nothing more.

**S4. Command allowlist includes general-purpose interpreters — INFORMATIONAL**
[Fact] `node`, `python`, `python3`, `bun`, `deno` are allowlisted (`lib/scriptValidation.js:7`), and `npm run <anything>` executes arbitrary package.json scripts regardless. [Judgment] The allowlist therefore prevents _accidental_ misuse, not determined misuse — which is the correct, honest framing for a tool whose job is to run dev servers. No action needed; keep SECURITY.md expectations calibrated.

Dependencies with CVEs: could not be verified offline (no `node_modules`, no registry access in the audit environment). Mitigating evidence: the lockfile pins electron 42.3.3 / electron-updater 6.8.9 (`package-lock.json:3680, 3763`), Dependabot runs weekly, and CI runs `npm audit --audit-level=high` (`ci.yml:30-32`, non-blocking).

### Correctness / data integrity (the ugly parts)

**C1. Silent total loss of all saved projects — HIGH (the single worst issue in the repo)**
[Fact] `ProjectStore.readProjects()` returns `[]` on _any_ read or parse error (`lib/projectStore.js:128-139`; the catch swallows everything). Every mutation then does read→modify→write of the whole file (`create` `:86-97`, `update` `:99-115`, `delete` `:117-126`). So: if `projects.json` is ever corrupt or transiently unreadable (crash mid-write, AV/file-lock on Windows, disk hiccup), the store reads `[]`, and the _next save of any project silently overwrites the file with only that project_ — every other project is gone, no error, no backup. Compounding it: `writeProjects` uses a plain non-atomic `writeFileSync` (`lib/projectStore.js:141-144`), which is precisely how the file gets truncated/corrupted in a crash. Consequence: real users of a released app losing data with no recovery path. This is the #1 fix.

**C2. "Stopped" is reported even when the process is still alive — MEDIUM-HIGH**
[Fact] POSIX `killProcessTree` sends a single SIGTERM and resolves immediately (`lib/projectLifecycle.js:81-91`); `stop()` waits at most 5s via `waitForChildExit`'s timeout (`:52-65`, `:342-344`), then unconditionally marks the state `stopped` (`:346-371`) because `state.child` is still set. A dev server that ignores SIGTERM (or a grandchild outside the process group) keeps running and holding the port while the UI shows "Stopped"; the user's next Start then fails with a confusing port conflict. No SIGKILL escalation exists. Consequence: orphaned processes — the exact failure Project Doctor exists to prevent.

**C3. IPv6-only listeners defeat the port check — LOW**
[Fact] `checkPortAvailable` binds only `127.0.0.1` (`lib/portUtils.js:39-61`), so a server listening only on `::1` leaves the port reported "available," and `findAvailablePort` may suggest a port that the project's own URL (`::1` is allowed by `urlValidation.js:3`) can't use. Niche; note only.

### Testing

**T1. `main.js`: 770 lines, 0% coverage — HIGH**
[Fact] No test requires `main.js` (verified by grep across `__tests__/`), despite `jest.config.js:6` listing it in `collectCoverageFrom` and `jest.setup.js:15-68` containing a complete Electron mock. Untested as a result: every IPC handler, `assertSafeProjectMutation` (`main.js:470-481` — the guard preventing config changes on running projects), `applyDoctorAction` (`main.js:483-509` — the only place Doctor patches mutate the store), preview bounds clamping (`normalizePreviewBounds` `main.js:109-132`), and tray logic. [Judgment] This is the highest-leverage testing gap because it is the layer SECURITY.md ("Scope" section) identifies as the security boundary.

**T2. `renderer-ui.test.js` asserts source-code strings, not behavior — MEDIUM**
[Fact] e.g. `expect(js).toContain('const sample = await state.api.createSampleProject();')` (`__tests__/renderer-ui.test.js:21-26`) and ~30 similar `html.toContain(...)` assertions. Consequence: a pure formatting change to `app.js` breaks tests; a real behavioral bug (wrong handler wired) passes them. These are change-detector tests, not behavior tests. `renderer-sample-ui.test.js` follows the same pattern.

**T3. No end-to-end/smoke test of the packaged app — MEDIUM**
[Fact] No Playwright/WebDriver harness exists; the closest is `integration.test.js` (59 lines, helpers only). [Judgment] One smoke test (launch app → create sample → start → reaches `ready` → stop) would have caught C2-class regressions; this matters because releases auto-publish installers (`release.yml:36-43`) with only unit tests as the gate.

**T4. Platform-specific branches never run in CI — MEDIUM** (see D2.)

What's good: the `lib/` suites are genuinely behavioral — e.g. `server-management.test.js` asserts full state transitions, diagnosis content, and event emission (`:28-159`); `preload.test.js` pins the whole IPC channel map (`:76-164`); fixtures use real temp dirs with cleanup (`integration.test.js:7-19`). No flaky patterns observed (fake `now`, injected fs, no sleeps except event-loop ticks).

### Performance

Healthy for its scale; two notes. [Fact] `ProjectStore` re-reads and re-parses `projects.json` on every `list()`/`get()` call (`lib/projectStore.js:78-84`), and `refreshTray()` rebuilds the entire tray menu + re-reads the store on every lifecycle state event (`main.js:689-694`, `:430-434`) — fine at N≤dozens of projects, just don't add per-log-line tray updates. Log/timeline growth is correctly bounded (`MAX_LOG_LINES=500` `projectLifecycle.js:8`; `MAX_TIMELINE_EVENTS=25` `projectDoctor.js:10`). Readiness polling continuing 30s post-stop (Q4) is the only real waste.

### Dependencies

Healthy in one sentence each: exactly one runtime dependency (`electron-updater`), which is the right number; lockfile v3 committed and consistent; Dependabot (weekly, grouped) + non-blocking `npm audit` in CI is an appropriate regime for this project; electron 42 / jest 30 / eslint 10 are all current-generation as of mid-2026; no license risks (MIT app, MIT/Apache deps).

### DevEx & operations

**D1. Version string is maintained in three places — MEDIUM (quick win)**
[Fact] `package.json:3` (`2.7.0`), hardcoded `version: '2.7.0'` in `preload.js:24`, and the assertion `expect(api.version).toBe('2.7.0')` in `__tests__/preload.test.js:39`. A release bump that misses one silently ships a wrong displayed version (the UI renders it at `app.js:1333`). Fix: `version: require('./package.json').version` in preload; the test compares against the same source.

**D2. CI tests on ubuntu only; Windows-specific code paths are release-time-only — MEDIUM**
[Fact] `ci.yml:11` runs a single `ubuntu-latest` job, while the code has win32-only behavior: `shell: true` spawn (`scriptRunner.js:34-40`) and `taskkill /T /F` process-tree kill (`projectLifecycle.js:72-79`). These first execute in CI at tag time (`release.yml:22, 34`) — i.e., after merging, during release. Consequence: Windows regressions are discovered at the worst possible moment.

**D3. No persistent logging or crash reporting in the packaged app — LOW**
[Fact] All main-process failures go to `console.error` (e.g. `main.js:336, 371, 397, 680, 710`), which is invisible in an installed app. [Judgment] For a distributed product, even `electron-log` file output would transform bug reports; full crash telemetry is overkill for this maturity.

Otherwise healthy: lint/format/test are all enforced as blocking CI steps (`ci.yml:22-26`), setup is `npm install && npm start` and works as documented, and the release pipeline is fully automated.

### Documentation

Healthy in one sentence: README is accurate against the code (security claims verified line-by-line), CHANGELOG follows keep-a-changelog and is current (2.7.0 / 2026-06-08), SECURITY.md defines a real reporting channel and scope, tests have their own README — the only gap is the absence of an architecture note explaining the three-layer design and the DI conventions in `lib/` (currently learned only by reading code).

### Strengths (what to preserve)

1. **Security architecture is the project's crown jewel** — the full Electron hardening checklist actually implemented and _accurately documented_ (`main.js:270-277`, `app.html:6-7`, `preload.js`, `lib/scriptValidation.js`, `lib/urlValidation.js`). Do not let refactors erode it; T1's tests should pin it.
2. **`lib/` dependency-injection discipline** (`fsImpl`/`now`/`idFactory` throughout, e.g. `projectStore.js:66-76`, `projectLifecycle.js:95-111`) — Electron-free core, the reason the existing tests are fast and deterministic. Every recommendation below reuses this pattern rather than introducing new ones.
3. **Behavioral unit tests for core logic** with honest fixtures (`server-management.test.js`, `project-store.test.js`, `preload.test.js`).
4. **Bounded everything**: logs, timeline, port scan (`projectLifecycle.js:8`, `projectDoctor.js:10`, `portUtils.js:64`) — no unbounded growth anywhere.
5. **Operational maturity beyond its size**: CI gates on lint+format+tests, Dependabot grouped updates, multi-OS release matrix, changelog, security policy.

---

## Phase 3 — Improvement Strategy

### Theme 1: Persistence must be durable and fail-closed (explains C1)

**Target state:** a corrupt or unreadable `projects.json` can never cascade into wiping projects; writes are atomic; a `.bak` of the last good state exists. **Principle:** _user data errors must be loud, never absorbed_ — distinguish "file absent" (legitimately `[]`) from "file unreadable" (throw / refuse to write).

### Theme 2: Process control must be truthful at the edges (explains C2, Q3, Q4, Q5)

**Target state:** "Stopped" means the process tree is dead (SIGTERM → grace → SIGKILL); cancellation uses the one AbortSignal mechanism that already exists; log lines are buffered whole. **Principle:** the UI's job is trust — runtime status must reflect OS reality, not intent.

### Theme 3: Test the privileged glue, not the source text (explains T1, T2, T3, A1)

**Target state:** IPC handlers extracted from `main.js` into a `lib/`-style module taking `{projectStore, projectLifecycle, dialog, shell, clipboard}` as injected deps (the codebase's existing pattern), unit-tested with the Electron mock that already exists in `jest.setup.js`; string-grep UI tests replaced with jsdom behavior tests; one packaged-app smoke test. **Principle:** test value concentrates where privilege concentrates.

### Theme 4: One source of truth across the bridge (explains A3, D1, the `'running'` drift)

**Target state:** doctor constants, status sets, and the version string defined once; the renderer consumes shared constants rather than re-declaring them. **Principle:** anything duplicated across the IPC boundary will drift — it already has.

### Explicitly NOT recommending (trade-offs)

- **No renderer framework / componentization rewrite** (React etc.): A2 is real but the UI is feature-stable, the rewrite risk exceeds the payoff at this maturity, and the Win95 aesthetic is hand-rolled CSS that frameworks wouldn't help with. Revisit only if renderer features keep growing.
- **No TypeScript migration**: high churn for a solo CJS codebase with good JSDoc habits. Cheaper 80%: `// @ts-check` + `checkJs` in CI later, if desired (not even scheduled below).
- **No code signing / notarization work**: it's a money/identity decision for the owner, not an engineering task (README already discloses the SmartScreen/Gatekeeper consequence honestly).
- **No crash-telemetry service**: file-based logging (D3) is the right-sized step; hosted telemetry is overkill and conflicts with the app's local-only ethos.
- **Not "fixing" S4** (interpreter allowlist): it's the product's purpose; document the threat model instead.

### Definition of done (measurable)

- Zero High findings open: C1 and T1 closed.
- `npm test` exercises ≥1 failure-injection test proving corrupt `projects.json` cannot cause data loss.
- `main.js` ≤ ~250 lines of pure wiring; extracted handler module ≥80% line coverage (`jest --coverage`).
- CI matrix runs tests on `ubuntu + windows + macos`; CI stays red on lint/format/test failure (already true — preserve).
- Stop-path test proves SIGKILL escalation after the grace period.
- `git grep -n "2\.7\.0" preload.js` returns nothing (version single-sourced).

---

## Phase 4 — Task Plan

### Quick wins (do immediately — all S effort, high impact-to-effort)

| #   | Task                                                                                            | Files                                                                                  | Risk                                                              |
| --- | ----------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| QW1 | Single-source the version: `require('./package.json').version` in preload; test reads same source | `preload.js:24`, `__tests__/preload.test.js:39`, ensure `package.json` in builder `files` | Very low                                                          |
| QW2 | Delete dead `new-window` handler and unused `dir:current`/`getCurrentDirectory`                  | `main.js:671,755-762`, `preload.js:55`                                                  | Very low                                                          |
| QW3 | CI test matrix: `os: [ubuntu-latest, windows-latest, macos-latest]`                              | `.github/workflows/ci.yml:10-11`                                                        | Very low (may surface real Windows failures — that's the point)   |
| QW4 | Remove phantom `'running'` status from renderer / align status sets                              | `app.js:2-8,135-147`                                                                    | Very low                                                          |
| QW5 | Add `%`, `^`, `"`, `'` to `SHELL_METACHARACTERS`                                                 | `lib/scriptValidation.js:12` + tests                                                    | Low (could reject exotic-but-legit args; acceptable)              |

### Milestone 0 — Safety net (before any refactor)

- **M0.1 — Failure-mode tests for ProjectStore (S)**: add tests for corrupt JSON, non-array shape, and read-throwing `fsImpl`, asserting current behavior, then flip expectations alongside M1.1. Files: `__tests__/project-store.test.js`. _Acceptance:_ tests exist and document the wipe scenario. Risk: none. Deps: none.
- **M0.2 — Stop-path tests for ProjectLifecycle (S)**: fake child that ignores kill; assert current (wrong) "stopped" report, flip with M1.2. Files: `__tests__/server-management.test.js`. Risk: none. Deps: none.
- **M0.3 — QW3 CI matrix** (listed above) so M1/M2 changes are validated on Windows. Deps: none.

### Milestone 1 — Critical fixes (correctness & data)

- **M1.1 — Durable ProjectStore (M)** — fixes C1. Atomic write (temp file + `renameSync`), write `projects.json.bak` of the last good state before overwrite, and fail closed: parse errors throw a typed store-corrupt error instead of returning `[]`; `main.js` catches it at startup and shows a recovery dialog (restore from `.bak` / start fresh) instead of silently proceeding. Files: `lib/projectStore.js:128-144`, `main.js:685-716`, tests from M0.1. _Acceptance:_ injected corrupt file ⇒ create/update/delete throw rather than wipe; kill -9 during write leaves either old or new file valid. Risk: medium (touches every save path) — contained by M0.1. Deps: M0.1.
- **M1.2 — SIGKILL escalation in stop (M)** — fixes C2 (+Q5 while there). After the SIGTERM grace (5s), send SIGKILL to the process group (POSIX) — Windows `taskkill /F` already force-kills; only mark `stopped` when exit is observed, else mark `running-unresponsive` with a Doctor warning; detach stale `onExit` by guarding on a per-start run id. Files: `lib/projectLifecycle.js:52-92,320-374`. _Acceptance:_ M0.2 tests pass with escalation; a stale-exit test shows no cross-run log bleed. Risk: medium (platform-specific) — mitigated by M0.3 matrix. Deps: M0.2, M0.3.
- **M1.3 — Use AbortSignal for readiness cancellation (S)** — fixes Q4. Pass an `AbortController.signal` from the lifecycle into `waitForReady`; abort in `stop()`/`onExit`; delete `readinessToken`. Files: `lib/projectLifecycle.js:162,286,327,427-433`. _Acceptance:_ test asserts probing stops immediately on stop. Risk: low. Deps: M1.2 (same functions).

### Milestone 2 — High-leverage improvements

- **M2.1 — Extract IPC handlers from main.js into `lib/ipcHandlers.js` (L)** — fixes A1, T1. Factory `createIpcHandlers({projectStore, projectLifecycle, dialog, shell, clipboard, …})` returning a channel→handler map; `main.js` reduces to registration + window/tray wiring. Follows the repo's existing DI convention exactly. Then unit-test the map with the existing `jest.setup.js` Electron mock: `assertSafeProjectMutation`, `applyDoctorAction`, `normalizePreviewBounds`, delete-stops-preview ordering, etc. Files: `main.js:470-672` → new `lib/ipcHandlers.js` + `__tests__/ipc-handlers.test.js`. _Acceptance:_ `main.js` ≤ ~250 lines; new module ≥80% coverage; preload channel-map test still green (it pins the contract). Risk: medium (a pure mechanical move, but it IS the privileged surface) — mitigated by the preload contract test + the M0 suite. Deps: M1.1, M1.2 (avoid refactoring under them).
- **M2.2 — Shared constants module across the bridge (M)** — fixes A3 + D1 remnants. Create `lib/shared/constants.js` (doctor checks, action ids, statuses, the AUTO_URL regex) consumed by `lib/` and by the renderer (copied into `public/` at build, or loaded as a plain script global — keep CSP `'self'`). Delete renderer re-declarations and `applyDraftDoctorAction`'s duplicate logic where possible. Files: `app.js:2-27,83-97,1059-1079`, `lib/projectDoctor.js`, `lib/projectLifecycle.js`. _Acceptance:_ `git grep` shows a single definition of each constant; renderer tests pass. Risk: medium (the renderer has no module system today — keep it a plain script global, matching the existing IIFE style). Deps: M2.1 ideally first.
- **M2.3 — Packaged-app smoke test (L)** — fixes T3. One Playwright-Electron (or WebdriverIO) test: launch → create sample project → start → wait ready → stop → quit clean. Run in CI on ubuntu (xvfb). Files: new `e2e/`, `ci.yml`. _Acceptance:_ CI fails if the start→ready→stop loop breaks. Risk: low-medium (CI flake potential — make non-blocking for the first week, then required). Deps: none hard; after M1 ideally.

### Milestone 3 — Quality & polish

- **M3.1 — Replace string-grep renderer tests with jsdom behavior tests (M)** — fixes T2. `testEnvironment: 'jsdom'` for renderer suites, load `app.html`, stub `window.localwrapAPI`, assert real interactions. Deps: M2.2 helps. Risk: low.
- **M3.2 — Migrate BrowserView → WebContentsView (M)** — fixes A4. `main.js:145-249`. _Acceptance:_ preview works; manual verify on one platform + smoke test (M2.3) green. Risk: medium (UI-visible). Deps: M2.3 recommended as the verifier.
- **M3.3 — Line-buffered output in scriptRunner (S)** — fixes Q3. Carry the partial-line remainder between chunks; flush on exit. `lib/scriptRunner.js:42-49` + test. Risk: low.
- **M3.4 — File logging via electron-log (S)** — fixes D3. Replace main-process `console.error` call sites. Risk: low.
- **M3.5 — Dedupe `getUrlPort`/`readPackageJson` into shared helpers (S)** — remainder of A3. Risk: low. Deps: M2.2.
- **M3.6 — IPv6 port-check fix or documented limitation (S)** — C3; optionally probe `::1` too. Risk: low.
- **M3.7 — ARCHITECTURE.md (S)**: one page on the 3 layers, the DI conventions, and the security-model decisions (the S3 trade-off, the S4 threat model). Risk: none.

### Top-3 implementation sketches

**1. M1.1 Durable ProjectStore.** In `writeProjects`: write to `${filePath}.tmp`, then `renameSync` over the target; before that, if the target exists and parses, copy it to `${filePath}.bak`. In `readProjects`: missing file → `[]`; existing-but-unparseable → throw a typed error (`error.code = 'STORE_CORRUPT'`, matching the repo's plain-Error style). In `main.js` startup, catch it and offer a dialog: "Restore backup / Start fresh (moves the corrupt file aside)". Gotchas: `renameSync` across devices fails (same dir here, fine); rename-over-existing works on NTFS but is covered by the M0.3 CI matrix anyway; keep the injected-`fsImpl` tests working by adding `renameSync`/`copyFileSync` to the fakes.

**2. M2.1 Extract IPC handlers.** Move `serializeProject`/`serializeRuntime`/`getProjectOrThrow`/`assertSafeProjectMutation`/`applyDoctorAction` plus the body of `registerIpcHandlers` into `lib/ipcHandlers.js` exporting `createIpcHandlers(deps)` → `{ 'project:list': fn, … }`; `main.js` does `for (const [channel, fn] of Object.entries(handlers)) ipcMain.handle(channel, fn)`. Inject window-dependent pieces (`sendToRenderer`, a preview controller) as functions, not the window object — wrap preview state in a small `createPreviewController(getWindow)` passed in. Keep `__tests__/preload.test.js` as the channel-name contract so no channel silently disappears.

**3. M1.2 Kill escalation.** Make `killProcessTree(child)` async and truthful: POSIX — `process.kill(-pid, 'SIGTERM')`, race child exit vs 5s, then `process.kill(-pid, 'SIGKILL')`, race again vs ~2s; return whether exit was observed. `stop()` sets `stopped` only on observed exit; otherwise `running-unresponsive` + a Doctor `process: warn` ("Process did not exit; it may still hold port X"). Add a per-start `runId`; `onExit` ignores events whose `runId` differs from the current one. Gotchas: the detached process-group kill needs the existing `child.pid` validity check (`projectLifecycle.js:68`); on Windows `taskkill /F` is already forceful — just verify the exit-observation logic; test with a fake child whose `kill` is a no-op.

### Dependency order

M0.\* → QW\* (anytime) → M1.1 → M1.2 → M1.3 → M2.1 → M2.2 → M2.3 → M3.\*

---

## Open Questions (need a human)

1. **Data-recovery UX (M1.1):** on a corrupt store, is a blocking startup dialog acceptable, or should LocalWrap auto-restore the `.bak` silently and just show a status message?
2. **Code signing:** any plan/budget for Windows EV / Apple Developer ID? It changes the priority of auto-update work (macOS auto-update is blocked on signing per `README.md:46`).
3. **Is `getCurrentDirectory` (`preload.js:55`) reserved for a planned feature**, or safe to delete (QW2)?
4. **Renderer roadmap:** if significant UI features are coming, A2's "no rewrite" call should be revisited — is the feature set stable?
5. **E2E appetite (M2.3):** is the added CI time/flake budget (~3-5 min/run) acceptable for a smoke gate, or should it stay tag-time only?
6. **Performance targets:** none are implied by the code; confirm there's no expectation of >100 saved projects, which would change the ProjectStore re-read pattern from "fine" to "fix."
