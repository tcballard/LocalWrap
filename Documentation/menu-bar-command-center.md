# Menu-bar command center

LocalWrap's menu-bar item is a compact control surface for apps you have
already reviewed in the main window. It uses the same reconciled runtime,
Project Doctor, Workspace Doctor, loopback URL, and process-ownership rules as
the rest of LocalWrap. Opening the menu performs no repository or filesystem
diagnosis.

## Status and primary action

The status item combines the approved LocalWrap menu-bar artwork with a small
monochrome state mark, so Ready, Running, and Needs Attention remain distinct
without relying on colour. The menu's first contextual action is one of:

- **Review Failure** when a blocker or failed runtime needs attention;
- **Open Ready Apps** when one or more validated local apps are ready; or
- **Resume** when the last-running workspace can be started safely.

Attention, Running, Ready, and Ready to Start sections appear only when they
contain items. Long project or workspace lists stay bounded; **Show in
LocalWrap** is always available for the complete view.

## Safe quick actions

Start and workspace actions use policy prepared away from the menu-open path.
Stop and Restart are enabled only when the current runtime is bound to the same
verified run identity represented by the menu snapshot. If configuration,
workspace validation, reconciliation, or ownership changes, LocalWrap rejects
the stale action and asks you to review the current state in the main window.

Saved-workspace shortcuts use the same target-specific Workspace Doctor checks
as starting from the main window. No menu action bypasses validation, trust, or
ownership checks.

## Runtime notifications

Runtime notifications are off by default and macOS permission is requested
only after you turn them on in LocalWrap Settings. Notifications cover three
meaningful transitions:

- Ready;
- Failed; and
- Unexpected Exit.

The first observed state and a run recovered after relaunch are quiet. Repeated
observations of the same failure do not notify again. Visible content contains
only a bounded project name and fixed transition text—never paths, commands,
URLs, ports, logs, errors, environment values, headers, or response content.
Click routing is held in memory and opens the relevant LocalWrap surface.

## Launch at Login and background behaviour

Launch at Login uses `SMAppService.mainApp` and reflects the actual macOS
registration state, including approval required in System Settings. It launches
LocalWrap only. Project autostart remains a separate per-project preference and
still waits for runtime reconciliation.

Closing the main window keeps LocalWrap and verified-owned apps running. Quit
attempts to stop only verified-owned process groups and surfaces any process it
cannot stop safely.
