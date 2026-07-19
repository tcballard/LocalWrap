# LocalWrap Product Roadmap

Status: approved for implementation on 2026-07-18.

LocalWrap is the native macOS control room for local applications: understand a
repository, start it safely, verify the running product, recover from failures,
and keep the essential state available from the menu bar.

## Delivery model

Each milestone ships through an isolated `codex/*` branch and pull request.
Generated Xcode projects and `.build` output remain uncommitted. A milestone is
complete only when its native unit tests pass, its UI target compiles, the built
application is inspected, and its public behavior is documented.

| Milestone | Status | Depends on |
| --- | --- | --- |
| 1. Live Preview v2 | In review | Existing loopback URL policy |
| 2. Open Repository | In review | Repository inspection contract |
| 3. Repository manifest | In review | Open Repository review flow |
| 4. Runtime reconciliation | In review | Process ownership ledger |
| 5. Needs Attention | Planned | Reconciled runtime and Doctor issues |
| 6. Menu-bar command center | Planned | Runtime reconciliation and Needs Attention |

## Product boundaries

- Selecting a folder or detecting a manifest never executes a command.
- Imported commands and changes are reviewed before persistence or execution.
- Embedded navigation remains limited to validated loopback HTTP(S) URLs.
- Reports, history, and manifests never store or export secret values.
- LocalWrap signals only processes whose ownership it can verify.
- Menu-bar actions pass through the same validation as main-window actions.
- LocalWrap does not become a source editor, terminal, debugger, Git client,
  container dashboard, deployment tool, or general-purpose browser.

## Milestone 1: Live Preview v2

Make the running local application a first-class peer to its configuration.

Acceptance:

- Preview opens in an immediately visible, user-resizable split pane.
- Back, Forward, Reload/Stop, Retry, Close, and Open in Browser are native,
  keyboard-reachable controls.
- External handoff opens the preview's current validated URL.
- Responsive, Phone, Tablet, and Desktop viewport presets are available without
  injecting or modifying application content.
- History, loading, failure, and navigation state reset between projects.
- Every in-preview navigation and redirect remains loopback-policy checked.
- A bounded diagnostics surface reports useful preview failures without
  collecting bodies, cookies, authorization headers, or query values.

## Milestone 2: Open Repository

Turn a selected repository into a reviewed project proposal with minimal typing.

Acceptance:

- `Open Repository…` is available from the welcome screen, File menu, and add
  flow through a native folder picker.
- Existing inspection proposes the name, command, free port, URL, and warnings.
- All suggestions are editable and show their provenance before confirmation.
- Cancel persists nothing and starts nothing.
- Unsupported or ambiguous repositories fall back to manual configuration.
- `Add Project` and explicit `Add & Start` remain separate actions.

## Milestone 3: Repository-native manifest

Make `.localwrap/workspace.json` a documented, versioned team contract.

Acceptance:

- Selecting a repository automatically detects `.localwrap/workspace.json` or
  `localwrap.json` and opens review; it never imports or runs automatically.
- Review exposes projects, paths, commands, ports, dependencies, health checks,
  warnings, blockers, and updates to existing records.
- Paths remain inside the selected root; unsafe commands and non-loopback URLs
  fail validation.
- Re-import updates deterministically instead of creating uncontrolled copies.
- Export round-trips through the same validator and produces stable Git diffs.
- The schema and secret-handling boundary are documented for repository use.

## Milestone 4: Crash-safe runtime reconciliation

Give LocalWrap trustworthy knowledge of processes it launched across relaunches.

Acceptance:

- An atomic, bounded ledger records run ID, project ID, process group, PID,
  command fingerprint, port, and start time without environment values.
- Launch reconciliation distinguishes exited, verified-owned, unverifiable, and
  conflicting records before autostart can create duplicate processes.
- PID reuse alone never proves ownership, and unverifiable processes are never
  signalled automatically.
- The last valid project or workspace selection restores safely.
- Closing the window keeps owned runs active; quitting stops only verified-owned
  runs and surfaces failures.

## Milestone 5: Needs Attention

Aggregate the smallest safe next action for current configuration and runtime
problems.

Acceptance:

- Stable issue identities deduplicate Project Doctor, Workspace Doctor, runtime
  exits, readiness timeouts, workspace operation failures, and preview failures.
- The sidebar presents one compact attention destination and count.
- Every issue names the affected project/workspace, consequence, and next action.
- Selecting an issue navigates to the relevant project, field, Doctor action, or
  runtime surface.
- Deterministic fixes require confirmation when they mutate saved configuration.
- Resolved issues leave the active list; diagnostic history remains bounded and
  redacted.

## Milestone 6: Status-first menu-bar command center

Make LocalWrap useful as ambient infrastructure without cramming the main window
into a menu.

Acceptance:

- One reconciled snapshot groups Attention, Running, Ready, and Ready to Start.
- The primary action is contextual: Resume, Open Ready Apps, or Review Failure.
- Project and workspace quick actions use the same validation and ownership gates
  as the main window.
- Status remains understandable without color and menu labels stay concise.
- Notifications are limited to meaningful Ready, Failed, and Unexpected Exit
  transitions and do not repeat unchanged failures.
- Launch at Login uses the native Service Management API and remains distinct
  from per-project autostart.

## Release gates

- Focused unit coverage plus at least one UI or end-to-end acceptance path.
- Keyboard, focus, VoiceOver semantics, reduced motion, light/dark appearance,
  minimum-window, loading, empty, error, and recovery states are reviewed.
- Loopback, command, redaction, persistence, and process-ownership safety tests
  remain green.
- `git diff --check`, XcodeGen generation, native unit tests, UI test compilation,
  and `./script/build_and_run.sh --verify` succeed before publication.
