# LocalWrap workspace manifest v1

A LocalWrap workspace manifest is a version-controlled description of the local
projects that make up a repository. It lets a team share project paths, safe
start commands, loopback URLs, dependencies, health checks, and useful workspace
groupings without sharing machine state or secret values.

The canonical location is:

```text
.localwrap/workspace.json
```

LocalWrap also recognises `localwrap.json` at the repository root. When both
files exist, `.localwrap/workspace.json` takes precedence.

Opening a repository only discovers and validates its manifest. LocalWrap shows
a review before writing any project or workspace records, and importing a
manifest never starts a process. Starting remains a separate, explicit action.

## Example

```json
{
  "localwrap": 1,
  "name": "Storefront",
  "projects": [
    {
      "autostart": false,
      "command": "pnpm dev",
      "dependsOn": [
        "api"
      ],
      "healthCheck": {
        "path": "/health"
      },
      "id": "web",
      "name": "Web",
      "openOnReady": true,
      "path": "apps/web",
      "port": 3000,
      "url": "http://localhost:3000"
    },
    {
      "command": "npm run dev",
      "id": "api",
      "name": "API",
      "path": "apps/api",
      "port": 3001,
      "url": "http://127.0.0.1:3001"
    }
  ],
  "workspaces": [
    {
      "id": "full-stack",
      "name": "Full stack",
      "projects": [
        "api",
        "web"
      ]
    }
  ]
}
```

The machine-readable schema is
[`schema/workspace-manifest-v1.schema.json`](schema/workspace-manifest-v1.schema.json).
The schema validates JSON structure; LocalWrap also performs filesystem,
command, dependency, health-check, and loopback URL validation during review.

## Validate without importing

The installed app includes a read-only validator for local checks and CI:

```bash
/Applications/LocalWrap.app/Contents/MacOS/LocalWrap validate-manifest .
```

Pass either a repository folder or a manifest path. Validation does not save
configuration, import projects, or execute commands. Exit code `0` means the
manifest is valid, `1` means review found blockers, and `2` means the command
was used incorrectly. Warnings are printed with their stable code and scoped
field but do not make an otherwise valid manifest fail.

## Root fields

| Field | Required | Meaning |
| --- | --- | --- |
| `localwrap` | Yes | Manifest format version. Version 1 requires the integer `1`. |
| `name` | No | Display name for the imported workspace. Defaults to the selected folder name. |
| `projects` | Yes | One or more project definitions. |
| `workspaces` | No | Named project groupings. When omitted or empty, LocalWrap proposes one workspace containing every project. |

Unknown root fields fail validation. This keeps the versioned contract explicit
and prevents unsupported configuration from appearing to work.

## Project fields

| Field | Required | Default | Meaning |
| --- | --- | --- | --- |
| `command` | Yes | — | Safe executable and arguments to launch. |
| `id` | No | Derived from `name` or position | Stable manifest identity used by dependencies and deterministic re-import. Explicit IDs are strongly recommended. |
| `name` | No | `id` | Display name shown in LocalWrap. |
| `path` | No | `.` | Project directory relative to the selected repository root. |
| `port` | No | `3000` | Local listening port from 1000 through 65535. |
| `url` | No | `http://localhost:<port>` | Validated loopback HTTP(S) URL with an explicit allowed port. |
| `autostart` | No | `false` | Whether the project is eligible for LocalWrap's explicit autostart workflow. Import itself never starts it. |
| `openOnReady` | No | `true` | Whether LocalWrap may open the project after readiness is confirmed. |
| `dependsOn` | No | `[]` | Project IDs that must become ready before this project can start. |
| `healthCheck` | No | Project `url` | Either a relative HTTP path or a complete validated loopback URL. |

Project IDs are normalised to stable lowercase slugs during review. Keep IDs
unique and unchanged once shared. Dependency references should use those IDs;
unknown references are blockers.

Paths must be relative. LocalWrap resolves `.` components and symbolic links,
then requires the resulting project directory to exist inside the selected
repository root. Absolute paths and paths that escape the root fail review.

### Commands

Version 1 accepts these executables:

```text
npm npx yarn pnpm node bun python python3 deno
```

Commands are an executable followed by whitespace-separated arguments. They
are not interpreted by a shell. Shell operators, substitutions, redirections,
quotes, globbing, and control characters are rejected. In particular, do not
use `;`, `&`, `|`, `$`, backticks, `<`, `>`, parentheses, braces, brackets,
`!`, `#`, `*`, `?`, `~`, `%`, `^`, quotes, or line breaks.

### URLs and health checks

Project and explicit health-check URLs must:

- use `http` or `https`;
- use `localhost`, `127.0.0.1`, or `[::1]` as the host;
- include a port from 1000 through 65535.

A health check contains exactly one of:

```json
{ "path": "/health" }
```

or:

```json
{ "url": "http://localhost:3000/health" }
```

A `path` must begin with `/` and is resolved against the project's validated
URL. Query strings and fragments from the project URL are not carried into the
resolved health-check URL.

## Workspace fields

The manifest calls saved project groupings `workspaces`.

| Field | Required | Meaning |
| --- | --- | --- |
| `projects` | Yes | Non-empty list of project IDs in the grouping. |
| `id` | No | Stable workspace identity. Explicit IDs are strongly recommended. |
| `name` | No | Display name. Defaults to the workspace ID. |

References that do not resolve to a reviewed project block the manifest from
being imported. A workspace must reference at least one manifest project.

## Review and re-import

Review exposes the manifest path and version, every project value and its
source, dependencies, health checks, warnings, blockers, and whether each item
will be added, updated, or left unchanged. Blockers disable import. No review or
import action executes a project command.

LocalWrap records the canonical manifest path and manifest item ID as
provenance. Re-importing the same manifest updates the matching saved project
or workspace rather than creating another copy. Existing LocalWrap record IDs
and creation history are preserved; unchanged records remain unchanged. Items
removed from the manifest are not silently deleted from LocalWrap.

For predictable re-imports:

- assign explicit, unique IDs to projects and workspaces;
- keep those IDs stable when names, commands, or paths change;
- refer to dependencies and workspace members by ID;
- review every proposed add or update before importing.

## Export and stable diffs

Export writes `.localwrap/workspace.json` only after building data that passes
the same v1 validation used for import. Exported paths remain relative to the
selected root; projects outside that root are reported and skipped.

Canonical output is UTF-8 JSON with two-space indentation, sorted object keys,
stable item and reference ordering, unescaped URL slashes, and one trailing
newline. Repeating an export without changing the reviewed configuration
produces the same bytes, keeping Git diffs focused on real changes.

## Secret-handling boundary

Treat the manifest as public repository content. Version 1 deliberately has no
fields for environment variables, secrets, headers, cookies, credentials,
authorization values, or tokens. Unknown fields—including `environment`,
`env`, `secrets`, `headers`, `cookies`, and `tokens`—fail validation.

Never place a secret in any supported string field, including a command
argument, URL, name, path, or health check. LocalWrap does not use the manifest
as a secret store and cannot make a committed secret safe. Keep sensitive
values in the project's existing ignored local configuration or an external
credential manager.
