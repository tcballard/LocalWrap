# Needs Attention and diagnostic privacy

Needs Attention is LocalWrap's recovery inbox, not an analytics dashboard. It
derives one bounded snapshot from all saved projects, reconciled runtime state,
Project and Workspace Doctor, retained workspace-operation failures, and Live
Preview failures. The snapshot is computed away from the main thread and the
sidebar reads that immutable result.

## Causal issue behavior

- Project Doctor, Workspace Doctor, runtime, and workspace-operation symptoms
  for the same underlying problem merge into one stable issue.
- An unresolved workspace-operation failure remains active when the selected
  workspace changes or persistence reloads.
- Evidence resolves only after a causal recovery signal, such as the affected
  project becoming Ready, an intentional stop, or a later successful result for
  that project and workspace target.
- Active issues and redacted change history are bounded. Repeated identical
  observations update the existing issue rather than creating notification
  noise.
- The global inbox always diagnoses all saved projects; it does not narrow
  itself to whichever workspace is currently visible.

Issue rows navigate only. Suggested actions are separate controls. Any action
that changes saved configuration presents explicit Before and After text, then
revalidates that the same issue and action are still current before applying
the change. Deep links expand the rolled-up Doctor surface, scroll to a stable
anchor, and move accessibility focus to the affected field, check, or project.

## Run history boundary

Run history stores at most 100 runs globally and 20 per project. Each run is
limited to 32 coarse state transitions and 20 fixed LocalWrap lifecycle events.
The document is capped at 256 KiB and stored in the private LocalWrap
Application Support directory using an owner-only directory (`0700`) and file
(`0600`), no-follow reads, atomic replacement, and directory synchronization.

The schema can contain only:

- SHA-256 references for run and project identifiers;
- bounded UTC timestamps;
- enumerated coarse runtime states and LocalWrap lifecycle events;
- an optional numeric exit code.

There are no fields for project names, working directories, commands, URLs,
environment values, output lines, request bodies, headers, cookies, or tokens.
History can be cleared for one saved project or globally.

## Support report contract

The support report is built from that restricted history schema and is capped
at 16 KiB. It uses shortened opaque references and revalidates every timestamp
and reference, including corrupted or untrusted in-memory values. The preview,
clipboard, export text, and export bytes are views of the same immutable string.
LocalWrap therefore never copies a report before the user has seen the exact
text that will leave the app.

Project Doctor applies the same handoff rule to its bounded 8 KiB diagnostic
report. **Preview Redacted Report** creates one immutable redacted artifact;
the sheet renders that exact artifact and its **Copy Report** action copies the
same string. There is no direct generate-and-copy path, so a later Doctor or
runtime refresh cannot change the clipboard payload after review.
