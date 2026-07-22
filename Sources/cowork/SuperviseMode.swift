import CoworkCore
import Darwin
import Foundation

/// The supervisor's own process (ADR 003 rule 1).
///
/// Cowork re-executes itself with `__supervise` and this takes over: it owns the
/// work for exactly the dispatch's lifetime, honours the death pipe, and posts the
/// terminal event. It is the half of a dispatch the orchestrator does not do — and
/// its existence is what lets `dispatch` return an id instead of a result.
enum SuperviseMode {
    /// Run one dispatch to a terminal outcome.
    ///
    /// `resolve` is the single backend resolver: the same `ResolvedBackend` that
    /// capabilities, send and dispatch use. Workspace and resume travel in
    /// `DispatchContext` so interactive sessions are rooted at the grant.
    static func run(dispatchID: String,
                    resolve: (String) -> ResolvedBackend?) async -> Never {
        guard let record = DispatchRecord.load(dispatchID) else {
            // Rule 0 means the record precedes the process, so its absence is not a
            // race — it is a bug, and exiting loudly beats running work nothing
            // knows about.
            FileHandle.standardError.write(Data("cowork: supervise: no record \(dispatchID)\n".utf8))
            exit(70)
        }

        // The death pipe is the no-orphans rule (ADR 003 rule 2). If the
        // orchestrator dies by any means — including SIGKILL — the kernel closes
        // its descriptors, this read hits EOF, and the dispatch goes with it. The
        // worker is killed first, then the fact is published: a caller must never
        // be left unable to tell a dead dispatch from a live one.
        Supervisor.waitForOrchestratorDeath {
            let latest = DispatchRecord.load(dispatchID)
            if latest?.state.isTerminal != true {
                Events.emit(id: record.id, parent: record.parent, root: record.root,
                            backend: record.backend, event: "cancelled",
                            detail: "supervisor.orchestrator-gone")
                var closing = latest ?? record
                closing.state = .cancelled
                closing.diagnostics.append("supervisor.orchestrator-gone")
                try? closing.save()
            }
            kill(-getpid(), SIGKILL)     // take the worker's group down with us
        }

        let workspace = record.workspace.map {
            Workspace(root: URL(fileURLWithPath: $0), writable: true)
        }

        // Resume comes from the record (a follow-up's predecessor handle); workspace
        // from the same record so interactive and one-shot see the same grant.
        let ctx = DispatchContext(workspace: record.workspace, resume: record.continues)
        let backend = resolve(record.backend)

        let sessionTransport: SessionTransport?
        if let backend {
            sessionTransport = try? backend.interactiveSession(ctx)
        } else {
            sessionTransport = nil
        }
        let session = sessionTransport.map { LiveSession($0) }
        let runner = backend?.oneShot(ctx)

        // The decision is made as a value first, by code the tests can reach
        // (`SupervisionPlan`), and only then acted on. The acting is what has to
        // live here — it exits the process — but the reasoning does not, and the
        // reasoning is what has to be correct: a supervisor that never reads
        // `record.interactive` passes a green suite while `send` is dead.
        switch SupervisionPlan.decide(record: record,
                                      hasInteractiveSession: session != nil,
                                      hasRunner: runner != nil) {
        case .refuse(let diagnostics):
            finish(record, state: .failed, result: "", diagnostics: diagnostics)

        case .runInteractive:
            guard let session else {
                // Unreachable: the plan only says this when a session exists. Saying
                // so beats a force-unwrap that would take the dispatch down silently.
                finish(record, state: .failed, result: "",
                       diagnostics: ["supervise.plan-inconsistent", "backend=\(record.backend)"])
            }
            let conclusion = await InteractiveSession(record: record)
                .run(isWorkerAlive: session.isAlive) { prompt in
                    await session.turn(prompt)
                }
            session.close()
            if !conclusion.transcript.isEmpty {
                try? Store.writeAtomically(Data(conclusion.transcript.utf8),
                                           to: Store.dispatchDir(record.id)
                                               .appendingPathComponent("output.log"))
            }
            finish(record, state: conclusion.state, result: conclusion.result,
                   diagnostics: conclusion.diagnostics, continuation: session.continuation())

        case .runOneShot:
            break
        }

        guard let runner else {
            // Unreachable for the same reason: `.runOneShot` implies a runner.
            finish(record, state: .failed, result: "",
                   diagnostics: ["supervise.plan-inconsistent", "backend=\(record.backend)"])
        }

        let outcome = await runner.execute(task: record.task, workspace: workspace)

        if !outcome.transcript.isEmpty {
            // Bulk output lives with the dispatch; the event stream stays under
            // PIPE_BUF so concurrent appends remain atomic (ADR 003 rule 9).
            try? Store.writeAtomically(Data(outcome.transcript.utf8),
                                       to: Store.dispatchDir(record.id)
                                           .appendingPathComponent("output.log"))
        }
        finish(record, state: outcome.state, result: outcome.text,
               diagnostics: outcome.diagnostics, continuation: outcome.continuation)
    }

    /// Every dispatch reaches a terminal event. No exceptions (ADR 003 rule 5).
//: @use-case:containment.failed_dispatch_keeps_its_workspace#failed_dispatch_keeps_it
    private static func finish(_ record: DispatchRecord, state: DispatchRecord.State,
                               result: String, diagnostics: [String],
                               continuation: String? = nil) -> Never {
        // Teardown first (ADR 002 rules 9–10): the POLICY — success only, every other
        // ending keeps its workspace — is `TerminalOutcome.teardownCommand`, where
        // tests reach it. The core runs the command without knowing what it is for;
        // a hook that fails is recorded beside the outcome, never allowed to change it.
        var diagnostics = diagnostics
        if let command = TerminalOutcome.teardownCommand(for: state, record: record) {
            let hook = Process()
            hook.executableURL = URL(fileURLWithPath: "/bin/sh")
            hook.arguments = ["-c", command]
            if (try? hook.run()) != nil { hook.waitUntilExit() }
            if hook.terminationStatus != 0 {
                diagnostics += ["on_terminal.failed", "exit=\(hook.terminationStatus)"]
            }
        }

        // What the ending *is* — the record, the event, the code — is decided by
        // `TerminalOutcome`, where tests can reach it. What is left here is doing
        // it: saving, emitting, exiting.
        let outcome = TerminalOutcome(record: record, state: state, result: result,
                                      diagnostics: diagnostics, continuation: continuation)
        try? outcome.closing.save()
        Events.emit(id: record.id, parent: record.parent, root: record.root,
                    backend: record.backend, event: outcome.event, detail: outcome.detail)
        exit(outcome.exitCode)
    }
}
