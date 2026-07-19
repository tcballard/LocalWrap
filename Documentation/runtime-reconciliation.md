# Runtime reconciliation and recovery

LocalWrap treats process ownership as evidence that must survive an application
relaunch. It never treats a reused PID, a matching command name, or an occupied
port as sufficient proof that a process is safe to control.

## What is persisted

The private runtime ledger contains a bounded set of active records. Each record
stores a random run ID, saved project ID, process/session identity, kernel start
time, redacted launch and observed-process fingerprints, port, start time, and a
private log filename. It does not store command text, arguments, environment
values, working-directory text, headers, cookies, or response bodies.

The ledger and log directory use owner-only permissions, reject symlinks, and
enforce bounded records and file sizes. Ledger replacement is same-directory,
atomic, flushed, renamed, and directory-synced before a prepared launch can be
committed. A post-rename durability error is reported explicitly rather than
blindly retried.

## Launch and relaunch behavior

LocalWrap first launches a tiny copy of its own executable as an isolated
session and process-group leader. That supervisor blocks on a private inherited
commit pipe; the reviewed project command does not exist yet. LocalWrap captures
the supervisor's kernel identity, atomically persists a `prepared` record, and
re-inspects that identity immediately before writing the commit byte. Only then
does the supervisor launch the project command and promote the record to
`running`.

If LocalWrap exits, identity capture fails, or the prepared write is not known
to be durable, the pipe closes and the supervisor exits without launching the
project. If LocalWrap exits after commit but before phase promotion, the stable
supervisor is already running and reconciliation restores monitoring without
replaying the commit. The supervisor remains the group leader while wrappers
such as npm and npx exec into their eventual target, so a command transition
cannot invalidate or weaken ownership evidence.

At launch, LocalWrap reconciles every ledger record before project autostart:

- **Exited** means the recorded leader and its whole process group are gone;
  the stale record can be removed.
- **Verified owned** means the recorded PID is still its own process-group and
  session leader, every persisted identity field agrees, and every inspected
  group member belongs to that user, group, and session; monitoring and
  readiness checks can resume.
- **Unverifiable** means macOS did not provide enough evidence; the record is
  preserved and no signal is sent.
- **Conflicting** means current identity or saved launch configuration differs;
  the record is preserved and no signal is sent.

An unresolved record blocks a duplicate start for its project.

Ledger transactions are serialized across LocalWrap processes with an
owner-only file lock, so two application instances cannot both observe an empty
ledger and launch the same project.

## Closing, quitting, and recovery

Closing the main window hides LocalWrap while its verified runs continue. The
last durable project or workspace selection is restored when it still exists.

Quitting inspects ownership immediately before `SIGTERM`, confirms the monitored
process still matches that fresh evidence, waits for the whole group, and
repeats both checks immediately before any `SIGKILL` escalation. A runtime that
lacks persisted ownership evidence is never signalled. Runtime records and logs
are removed only after the group is confirmed empty. If any record is uncertain,
conflicting, or survives cleanup, quitting is cancelled and the user can either
return to LocalWrap or explicitly quit while leaving those processes untouched.
