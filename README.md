# LocalWrap for macOS

LocalWrap is a native macOS cockpit for local development projects. Save local
commands, start and monitor processes, diagnose configuration problems, preview
loopback URLs, and resume dependency-aware workspaces without terminal juggling.

## Live Preview

When a project reaches Ready, choose **Live Preview** in its toolbar to open the
running app beside its LocalWrap configuration. The native preview includes
Back, Forward, Reload/Stop, current-URL browser handoff, and responsive, Phone,
Tablet, and Desktop viewport widths. Embedded navigation is restricted to
validated loopback HTTP(S) URLs; user-selected public links open in the default
browser instead.

## Open Repository

Choose **Open Repository…** from the welcome screen, File menu, or Add Project
screen to inspect an existing repository. LocalWrap proposes a project name,
package script, available port, and loopback URL, then shows every value and its
source in a review sheet. Folder selection never saves or runs anything:
**Add Project** saves the reviewed configuration in a stopped state, while
**Add & Start** is the explicit execution action. Ambiguous or unsupported
repositories stay editable and require a command before they can be added.

## Repository manifest

Teams can commit `.localwrap/workspace.json` to describe a repository's local
projects, commands, ports, dependencies, health checks, and saved workspace
groupings. `localwrap.json` at the repository root is also recognised, with the
`.localwrap` file taking precedence. Opening the repository shows an add/update
review first; it never imports or runs the manifest automatically.

Manifest paths must remain inside the selected repository, commands use
LocalWrap's safe executable allowlist, and URLs remain loopback-only. The v1
contract deliberately excludes environment values, secrets, headers, cookies,
credentials, and tokens. See the
[workspace manifest v1 guide](Documentation/workspace-manifest-v1.md) and its
[JSON Schema](Documentation/schema/workspace-manifest-v1.schema.json).

Validate a repository or manifest without importing, saving, or starting
anything:

```bash
/Applications/LocalWrap.app/Contents/MacOS/LocalWrap validate-manifest .
```

The validator exits `0` for a valid manifest, `1` when review finds blockers,
and `2` for invalid command usage. Diagnostics include the affected project or
workspace, field, and stable validation code; warnings do not make a valid
manifest fail.

## Crash-safe runtimes

LocalWrap keeps a private, bounded ownership ledger for active projects. Before
a reviewed command can start, a LocalWrap-owned supervisor establishes a new
macOS session and process group, its kernel identity is written durably, and
that identity is checked again. If LocalWrap closes or fails before the commit,
the project command never starts. After a relaunch, reconciliation runs before
autostart and classifies each record as exited, verified-owned, unverifiable, or
conflicting, preventing duplicate or unsafe control.

Closing the main window leaves verified projects running and the menu bar
available. Quitting stops only freshly re-verified process groups; LocalWrap
never sends a signal when identity evidence is missing or conflicting. See
[runtime reconciliation and recovery](Documentation/runtime-reconciliation.md)
for the persisted fields, recovery behavior, and safety boundary.

## Needs Attention and support reports

**Needs Attention** is one compact recovery inbox for Project Doctor,
Workspace Doctor, runtime, readiness, workspace-start, and Live Preview
problems. Repeated observations merge into one causal issue. Selecting its row
opens the affected field, Doctor check, workspace project, runtime output, or
preview; configuration-changing fixes remain separate buttons with a
before-and-after confirmation.

LocalWrap also keeps a private, bounded lifecycle history: coarse states,
timestamps, exit codes, and fixed LocalWrap lifecycle events only. It never
records command output, project names, paths, URLs, environment values, request
bodies, headers, cookies, or credentials. **Preview Support Report** shows the
exact redacted text before **Copy Report** is enabled. History can be cleared
for one project or globally. See
[Needs Attention and diagnostic privacy](Documentation/attention-and-recovery.md).

The next product milestones are documented in [ROADMAP.md](ROADMAP.md).

## Requirements

- macOS 15 or newer
- Xcode 26 or newer
- XcodeGen 2.44.1 or newer

## Build and run

```bash
brew install xcodegen
./script/build_and_run.sh --verify
```

Debug builds are named `LocalWrapMac`, use bundle ID
`com.localwrap.app.native`, and store data in
`~/Library/Application Support/LocalWrapNative-Debug`.

## Test

```bash
xcodegen generate --spec project.yml --project .
xcodebuild -project LocalWrap.xcodeproj -scheme LocalWrapMac \
  -destination 'platform=macOS' -derivedDataPath .build/LocalWrapMac test
./script/soak_native_macos.sh
./script/verify_native_macos_release.sh
```

The Release product is the universal `LocalWrap.app`, bundle ID
`com.localwrap.app`, with storage in
`~/Library/Application Support/LocalWrapNative`. First launch validates and
copies compatible data from the former Electron LocalWrap store without editing
the source file.

## Install with Homebrew

Unsigned pre-releases are published through the `tcballard/homebrew-tap` Cask:

```bash
brew tap tcballard/tap
brew install --cask localwrap
```

The release workflow marks the GitHub Release as a pre-release and updates the
Cask with the exact DMG version and SHA-256. The repository secret
`HOMEBREW_TAP_TOKEN` must have Contents read/write access to
`tcballard/homebrew-tap`. These builds are ad-hoc signed only: they are not
Developer ID signed or Apple-notarized, so Gatekeeper will warn or block them
on first launch.

## Signed distribution

`./script/release_native_macos.sh` archives, Developer ID-signs, packages,
notarizes, staples, Gatekeeper-verifies, and checksums the universal DMG. It
fails closed unless the required Apple signing and notarization credentials are
available.
