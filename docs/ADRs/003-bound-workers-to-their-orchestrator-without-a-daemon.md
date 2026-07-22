# ADR 003: Bound every worker to its orchestrator, without a daemon

## Status

Accepted - 2026-07-16

Depends on: [ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md).

## Context

Cowork's contract ([ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md))
requires this of the machinery beneath it:

- **no worker outlives the orchestrator that fired it** — a running agent with
  nobody left to collect its result is a liability, not a feature: it burns
  budget, it can still mutate a workspace, and its output will never be read;
- **every host can observe dispatches** — four host CLIs run as separate
  processes on one Mac, and a monitor may watch from outside the session that
  fired the work;
- lifecycle events form **one stream any plugin or agent can watch**;
- dispatches are **attributed** to their orchestrator, including when a worker
  dispatches its own workers.

The obvious reading of "shared, observable, durable" is a background service: a
daemon owning state, a protocol for clients, supervision to keep it alive, an
installer to place it, and a schema to migrate as it evolves. That reading is
wrong and expensive — it makes the runtime a distributed system before a single
agent runs. The operating system already provides sharing and durability.

The harder half is the first requirement. macOS offers no `PR_SET_PDEATHSIG`: a
child is **not** killed when its parent dies, and an orphan is re-parented to
`launchd` and keeps running. Death has to be arranged deliberately; it is not the
default, and assuming otherwise is how zombie agents happen.

## Decision

**Cowork has no daemon. A worker's life is bounded by its orchestrator's.**
State lives on the filesystem.

> **Implementation status (current Swift build).** The rules below are the full
> design; this note says which parts ship today. **Shipped:** the write-ahead
> record (rule 0), a supervisor per dispatch (rule 1), the death pipe + explicit
> shutdown + reconciliation (rule 2), `SIGTERM`→`SIGKILL` grace (rule 4), every
> dispatch reaching a terminal event (rule 5), `RLIMIT_CPU` (rule 7, CPU only),
> and the filesystem store, append-only event stream, atomic-rename durability,
> and environment attribution (rules 8–11). In the ordinary case a worker cowork
> spawns cannot outlive its orchestrator — the death pipe and the process-group
> kill see to that — and a CPU-bound escapee is killed by the kernel.
> Reconciliation marks an abandoned dispatch cancelled when its owner is gone; it
> does not itself kill a surviving worker, so an escapee that leaves its group is
> best-effort (detected and reported, not always prevented — see the Evidence
> below).
>
> **Designed but not yet shipped:** the descendant sweep + containment-fault
> report (rule 3 — cowork kills the worker's process group but does not yet track
> and sweep individually-orphaned descendants), the `O_EXCL` concurrency slots
> (rule 6 — no machine-wide concurrency cap is enforced yet), and the
> address-space / file-size / descriptor rlimits (rule 7 sets `RLIMIT_CPU` only).
>
> **Workspace is a grant, not a sandbox.** A dispatch's `workspace` `chdir`s the
> worker into a directory; it is **not** filesystem confinement — a worker is not
> stopped from reading or writing elsewhere. The Seatbelt experiments in the
> Evidence below explore a *future*, stronger confinement (allow-list writes,
> deny-list reads) that is **not** part of the current build. CLI workers' own
> sandboxes are not trusted: Codex runs with its sandbox off
> (`danger-full-access`), so cowork's hold on a worker is the process group, the
> death pipe, and `RLIMIT_CPU`. The honest current guarantee is "a worker cannot
> outlive its orchestrator or burn unbounded CPU" — not "a worker cannot touch
> your filesystem."

0. **A dispatch is recorded before it exists.** The record is written and
   published *before* the process is spawned, never after. Spawn-then-record has
   a window in which a crash leaves a running worker nothing knows about — an
   untracked process is a leak with no name, and no later reconciliation can
   recover what was never written down. Write-ahead makes the record, not the
   process, the source of truth: every worker cowork has ever started is
   knowable, in flight or terminal, without exception.
1. **Every dispatch is a supervisor process.** Cowork spawns a small supervisor
   which owns the real work (a CLI child, or an endpoint loop in-process). The
   supervisor holds the death pipe, owns the process group, enforces the timeout,
   runs teardown, and posts events. It exists for exactly the dispatch's lifetime.
2. **No orphans, ever.** A worker must not survive its orchestrator. This is a
   safety property, not a convenience, and it is enforced by three mechanisms
   that cover each other's gaps:
   - **A death pipe.** Each supervisor inherits an open pipe from the
     orchestrator. If the orchestrator dies — including by `SIGKILL` — the
     kernel closes its descriptors, the supervisor reads EOF immediately, and
     terminates. This is kernel-enforced and needs no polling and no cooperation
     from the dying process.
   - **Explicit shutdown.** On clean exit the orchestrator terminates its
     supervisors' process groups directly, rather than waiting for them to
     notice.
   - **Reconciliation.** Any cowork invocation reconciles dispatches recorded as
     live whose process is gone: it kills survivors, runs their teardown, and
     posts their terminal event. This catches the residual case where both
     orchestrator and supervisor die at once.
3. **Each worker owns a process group, and the group is not enough.** Killing the
   group is the first move: it cannot take the orchestrator with it, and it
   reliably takes ordinary descendants. But a CLI agent may put its helpers in
   their own process group, and Claude Code does (see Evidence). Containment is
   therefore three steps, in order:
   - kill the worker's process group;
   - kill the descendants cowork recorded while the dispatch was alive, since a
     helper that has already orphaned cannot be found by walking a tree from a
     dead parent;
   - verify, and if anything cowork spawned is observably still alive, **report a
     containment fault**. Cowork never claims a clean termination it did not
     achieve. An escape is a fact to publish, not a detail to swallow.
4. **A killed worker gets to clean up and say so.** Termination is
   `SIGTERM`, then a grace period, then `SIGKILL` of the process group. Within
   the grace period the supervisor posts its terminal event and runs teardown.
5. **Every dispatch reaches a terminal event. No exceptions.** If a supervisor
   dies without reporting, its orchestrator reports on its behalf. If both die,
   reconciliation reports it on the next invocation. A dispatch never silently
   disappears from the stream — silence is the one outcome cowork must never
   produce, because a caller cannot distinguish it from work still in progress.
6. **Concurrency is bounded per backend, without a daemon.** A dispatch acquires
   a slot by creating a slot file with `O_EXCL`; slots whose owning process is
   gone are reclaimed by liveness check. That gives machine-wide limits — which
   matter most for locally hosted models, where the constraint is one GPU — with
   no arbiter process.
7. **The kernel enforces resource bounds, not cowork.** Every worker is spawned
   under hard `setrlimit` limits — CPU seconds, address space, file size,
   descriptors. These are inherited across `fork`, `exec` **and `setsid`**, cannot
   be raised by the process they bind, and are enforced by the kernel with no
   bookkeeping whatsoever.

   This is the one guarantee that survives every escape in the Evidence below. A
   worker that leaves its process group, orphans itself, and is forgotten
   entirely by cowork still cannot burn the machine: the kernel `SIGXCPU`s it.
   Where the OS will do the work, cowork delegates rather than reinventing it —
   the kernel is a better bookkeeper than any registry cowork could keep, because
   it cannot be crashed, raced, or forgotten.
8. **The filesystem is the shared store.** Every host reads the same directory,
   so all four can observe the same dispatches with no protocol, no server, and
   no client library.
9. **The event stream is an append-only file.** Concurrent writers are safe
   without coordination: POSIX guarantees `O_APPEND` writes below `PIPE_BUF`
   (4096 bytes) are atomic. Event lines therefore stay small, and bulk worker
   output goes to a per-dispatch log rather than into the stream.
10. **State updates are atomic by rename.** Write a temporary file, `rename(2)`
   over the target. That is the whole durability mechanism.
11. **Attribution rides the environment.** The current dispatch's identity is
   injected into each worker's environment, so a worker calling cowork is
   attributed with no coordination.

## Consequences

**Positive**

- An entire class of machinery never exists: no service, no protocol, no
  versioned wire format, no client SDK, no supervision, no installer for a
  background component, no schema migrations.
- Nothing is left running. Closing a host CLI cannot leave an agent editing a
  workspace unattended, which is the failure mode that most deserves preventing.
- Consumers are universal. `tail -f` on the event stream is a first-class client,
  on equal terms with any panel or monitor agent.
- No single point of failure: one broken dispatch cannot take down another,
  because no process is shared.

**Negative and accepted costs**

- **No fire-and-forget across sessions.** A long dispatch dies with the session
  that fired it. Work in progress is lost, and there is no "start it now, collect
  it tomorrow". This is the direct price of the no-orphans rule and it is paid
  knowingly.
- **A supervisor process per dispatch.** The death pipe, the process group, the
  timeout, teardown, and event reporting all need something alive that cowork
  controls. That is one extra process per dispatch — the price of never leaking a
  worker, and the reason `SIGKILL` of the orchestrator is survivable.
- **The residual death gap is small but real.** The death pipe is immediate and
  kernel-enforced, so an orchestrator dying by any means kills its workers. The
  remaining hole is both the orchestrator *and* a supervisor being `SIGKILL`ed in
  the same instant: that worker survives until reconciliation notices, which
  requires someone to invoke cowork. Bounded by the next invocation, not by a
  clock.
- **Reconciliation makes the stream eventually truthful, not instantly.** A
  dispatch whose supervisor was `SIGKILL`ed is reported terminal when the next
  invocation reconciles it, so its terminal event can lag reality. It always
  arrives; it is not always prompt.
- **Slot files can leak.** A process that dies without releasing its slot leaves
  it held until a liveness check reclaims it. Concurrency limits are therefore
  self-healing rather than exact, and a pid can in principle be reused before
  reclamation.
- **Containment is best-effort against a hostile or careless CLI.** A vendor CLI
  that puts helpers in their own process group defeats `killpg`, and one whose
  helper has already orphaned cannot be found by walking a tree. Cowork tracks
  what it spawned and sweeps, but a determined escape wins. macOS offers no
  cgroup-equivalent to make this airtight. The honest limit is: cowork detects
  and reports an escape; it cannot always prevent one.
- **State can be observed mid-flight.** A reader may see a dispatch between
  atomic writes and must tolerate a moment-stale state. There are no transactions
  across files.
- **`PIPE_BUF` is a real constraint, not a detail.** An event line over 4096
  bytes loses its atomicity guarantee and can interleave, which binds every
  future addition to the event schema.
- **The stream grows without bound** and needs rotation — a small amount of work
  a daemon would otherwise have owned.

## Validation and evidence

Validated on 2026-07-16 against a real host, before any implementation.

**Proven.**

- *Process-group kill contains an ordinary tree.* A leader in its own group with
  three descendants: 4 members before `kill -TERM -pgid`, 0 after, no strays.
- *The death pipe fires on `SIGKILL` of the orchestrator.* A child holding only
  the read end of an inherited pipe had `sysread` return 0 — EOF — the moment the
  parent was `SIGKILL`ed, and exited. No polling, no cleanup handler in the dying
  process, no detection window. This is the mechanism the no-orphans rule rests
  on and it behaves as claimed.
- *Signalling a process group you do not own kills you instead.* Demonstrated
  accidentally, by signalling a mis-derived pgid and killing the tooling that
  sent it. Hence the ordering above, and hence each worker owning its own group.

**Disproven — a real CLI escapes the process group.**

Claude Code runs its background PTY host in **its own process group**, not its
parent's:

```text
  PID   PGID  PPID  ETIME        COMM
  1234  1234  9999              claude               <- worker, group 1234
  1235  1235   1234              claude bg-pty-host   <- child of 1234, group 1235
 5678  5678     1  1d claude bg-pty-host   <- orphan, PPID 1, alive 1 day
```

A `killpg` of the worker's group therefore does **not** reach its helpers, and an
orphaned helper was found alive having survived over a day —
re-parented to `launchd`, exactly the failure this ADR exists to prevent. The
escape is not hypothetical and it is not ours to fix in the vendor's CLI.

This is why containment is three steps rather than one, and why an unkillable
escape is reported rather than assumed away. It also means this ADR's
confirmation is a genuine test that would fail today against a naive
implementation — which is the point of writing it down.

**Total containment is not available to an unprivileged process on macOS.**

Every kernel mechanism that would deliver it was tested and rejected by the OS:

```text
  kqueue EVFILT_PROC   NOTE_EXIT   OK
                       NOTE_FORK   OK      (says a fork happened...)
                       NOTE_EXEC   OK
                       NOTE_TRACK  ENOTSUP (...but never says what it made)
  audit sessions       setaudit_addr(AU_ASSIGN_ASID)  EPERM
  cgroups              do not exist on macOS
```

`NOTE_TRACK` is the only mechanism that reports a forked child's pid to a
watcher, and the kernel refuses it. Audit sessions would give an inherited,
unforgeable group identity, and creating one requires privilege. So a watcher
cannot be *told* about descendants; it can only *look* for them, and looking
races with a process that forks, escapes its group, and is orphaned between two
looks.

Environment stamping was tested as a way to find escapees by identity and does
not work either: `KERN_PROCARGS2` returns a process's argv but macOS redacts its
environment, and `ps -E` shows nothing even for one's own child. A worker cannot
be found by a mark it carries.

**What the kernel *will* do, it does perfectly.** Hard `setrlimit` limits were
tested against the same escape:

```text
  setrlimit(RLIMIT_CPU, 2s hard) -> spawn tree -> child setsid()s away

  22264 Cputime limit exceeded: 24   perl ... POSIX::setsid(); exec ...   ESCAPEE KILLED
  22265 Cputime limit exceeded: 24   perl -e '1 while 1'                  child killed
  survivors: 0
```

The limit is inherited across `fork`, `exec` and `setsid`, cannot be raised, and
the kernel enforces it against a process cowork can neither see nor name. This is
why rule 7 delegates resource safety to the OS: a registry cowork keeps can be
crashed, raced, or forgotten; an rlimit cannot.

Its honest boundary: rlimits bound *consumption*, not *existence*, and they are
per-process rather than per-tree. An escapee burning CPU dies. An escapee sitting
idle — like the day-old `bg-pty-host` found here — consumes almost nothing and so
never trips a limit; it is caught by the sweep and the fault report, not by the
kernel.

**Workspace confinement of a real CLI agent works, with an asymmetry worth
naming.** Claude Code was run under `sandbox-exec` against a live task:

```text
  claude under Seatbelt   -> worked: wrote the file, replied DONE
  workspace write         -> landed
  ~/.ssh/id_ed25519 read  -> Operation not permitted
  write outside workspace -> Operation not permitted
```

The profile shape that succeeds is not symmetric, and the asymmetry is the
finding:

```text
  (allow default)                       ;; permissive base
  (deny file-read* <secret paths>)      ;; reads: DENY-LIST  -> best-effort
  (deny file-write*)                    ;; writes: ALLOW-LIST -> strong
  (allow file-write* <workspace> <cli state> <caches>)
```

A deny-default profile with a read allow-list is strictly stronger and **breaks
the agent** — it requires exhaustively knowing every path a vendor CLI reads, and
missing one produces silent failure rather than a diagnostic. The workable
profile therefore allow-lists *writes* and deny-lists *reads*.

That maps onto the actual threat model rather than an idealised one: **damage is
allow-listed and strongly confined; exfiltration is deny-listed and only
best-effort**, blocking what we thought to name. A worker cannot write outside
its workspace. A worker could still read a secret nobody added to the list. That
is a real limit, stated rather than glossed, and it means the confinement claim
is "cannot damage your machine", not "cannot see your machine".

The honest limit, therefore — and the distinction that matters:

| Target | Cowork's control |
|---|---|
| **Knowing every worker it started, in flight and completed** | **Total** — this is bookkeeping, not kernel cooperation. Rule 0 guarantees it. |
| Its own supervisor and direct children | **Total** — death pipe + owned process group |
| A cooperative CLI's descendants | **Total in practice** — they stay in the group |
| A vendor CLI's helper that escapes its group *and* orphans | **Best-effort** — kill what is reachable, then detect and report |

The first row is the one that must never slip, and it never does: it depends on
cowork writing things down in the right order, not on the kernel agreeing to
help. Cowork cannot forget a worker, cannot lose one, and cannot leave one in an
unknown state — because the record precedes the process and every record reaches
a terminal event (rule 5).

The last row is a property of somebody else's software running on an OS with no
cgroups. Cowork's answer there is not to pretend: it kills everything it can
reach and publishes a containment fault for anything that survives, so a leak is
always visible even when it is not preventable.

Genuine 100% for the last row needs one of: Seatbelt `(deny process-fork)`, which
is total for workers that never spawn (an endpoint loop) and impossible for a CLI
agent whose job is running tools; a virtual machine; or EndpointSecurity with an
entitlement and root. Each is a different product.

Cowork therefore promises what it can keep: it never loses track of what it
spawned, it kills everything it can reach, and it reports — loudly — anything
that survived. A tool that claims total control it does not have is lying, and
lying is the one thing this design forbids.

**Rule 5 was violated, and is now closed.** Performing the journey — not a unit
test — found that killing the server mid-dispatch left a record at `started`
forever. Silence is the one outcome this ADR forbids, because a caller cannot
tell it apart from work still in progress. Reconciliation fixes it, proven by
reproducing the exact failure:

```text
  before:  SIGKILL the server mid-dispatch  ->  queued -> started -> (silence)
  after:   SIGKILL the server mid-dispatch  ->  queued -> started -> cancelled
                                                          reconciled.owner-gone
```

The terminal event was emitted by the *next invocation* — a bare `tools/list`,
not a dispatch — because with no daemon there is no background sweeper and any
invocation reconciles. A live dispatch in the same store was correctly left
alone, so the sweep does not false-positive.

Two details are load-bearing:

- **Owner identity is (pid, start time), never a bare pid.** Pids are recycled, so
  `kill(pid, 0)` can report a live owner that is really an unrelated process, and
  the abandoned dispatch would then be believed alive forever. The kernel's
  recorded start time for that pid cannot be reproduced by a recycled one.
- **Rule 0 is what makes this possible.** Because the record precedes the
  process, an abandoned dispatch is always findable. That is the cost of
  write-ahead being repaid: nothing can be running that was never written down.

The reconciled state is `cancelled`, not `failed`: under the no-orphans rule a
worker does not outlive its orchestrator, so an owner's death *is* a cancellation
by cowork's own design, and blaming the backend for it would be a small lie.

## Confirmation

The decision holds while cowork ships no background service.

It is working when killing an orchestrating session — including with `SIGKILL` —
leaves no process cowork spawned alive, verified by process inspection rather
than by assumption; and when any process that does survive is reported as a
containment fault rather than silently ignored.
