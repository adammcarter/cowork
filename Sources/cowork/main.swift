import CoworkCore
import CoworkSugar
import Foundation
import MCP

// Cowork dispatches work to an agent and manages that dispatch. Truthfully.
// That is all. (ADR 000)
//
// Providers are configuration, not code (ADR 005): global ∪ project, masked by
// the union of the project's selected profiles. Nothing here names an endpoint.
//
// This is the walking skeleton: one thread through the whole system — dispatch a
// real task to a real model and report what really happened. Nothing is built
// here that this journey does not demand.


let superviseID = ProcessInfo.processInfo.environment["COWORK_SUPERVISE"]

// With no daemon there is no background sweeper, so reconciliation runs on any
// invocation: an abandoned dispatch is reported the next time cowork is asked
// anything at all (ADR 003 rule 5). Eventually truthful, never silent. A
// supervisor skips it — it is one dispatch's process, not an orchestrator.
try? Store.prepare()
if superviseID == nil { Reconcile.sweep() }

let globalConfig = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cowork/config.toml")
let projectConfig = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("cowork.toml")
// A config mistake is the user's to fix, so it exits with a diagnosis rather than
// a stack trace: cowork failing to start must never look like cowork being broken.
let config: Config
do {
    config = try Config.load(
        global: globalConfig,
        project: FileManager.default.fileExists(atPath: projectConfig.path) ? projectConfig : nil)
} catch let error as ConfigError {
    FileHandle.standardError.write(Data("cowork: \(error.description)\n".utf8))
    exit(78)   // EX_CONFIG
} catch {
    FileHandle.standardError.write(Data("cowork: config.unreadable: \(error)\n".utf8))
    exit(78)
}

/// Single resolution entry point for every path: dispatch, send, follow-up,
/// capabilities, and the supervisor. A backend id is `provider/model` for an
/// endpoint, or a configured CLI name (ADR 005).
func resolveBackend(_ id: String) -> ResolvedBackend? {
    BackendResolver.resolve(id, config: config)
}

// Re-executed as a supervisor: own this one dispatch and exit. Same binary, so
// there is one artifact to build, sign and ship, and the supervisor is always the
// exact version that spawned it (ADR 003 rule 1).
if let superviseID {
    // Workspace + resume come from the record inside SuperviseMode via
    // DispatchContext; resolve only names the backend.
    await SuperviseMode.run(
        dispatchID: superviseID,
        resolve: { resolveBackend($0) })
}

// An `env:NAME` reference — a provider's `credential`, or a CLI row's
// `[cli.*.env]` value — names a variable in THIS process's environment. The
// supervisor is a fresh process with a fresh environment, so it cannot resolve that
// name unless the value travels with it: without this, a user who exports their key
// exactly as the config says gets a failed dispatch, or (for a CLI descriptor) a
// silently empty variable in the worker.
//
// Only the names the config actually references are forwarded, and only if set:
// the supervisor's environment stays an allowlist rather than an inheritance.
let credentialEnvironment: [String: String] = config.referencedEnvironmentNames
    .reduce(into: [:]) { out, name in
        if let value = ProcessInfo.processInfo.environment[name] { out[name] = value }
    }

let dispatcher = Dispatcher(executable: URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(),
                            supervisorEnvironment: credentialEnvironment)
/// Death pipes are held for the dispatch's lifetime: closing one tells its
/// supervisor the orchestrator is gone.
final class LiveDispatches: @unchecked Sendable {
    private var fds: [String: Int32] = [:]
    private let lock = NSLock()
    func keep(_ id: String, _ fd: Int32) { lock.lock(); fds[id] = fd; lock.unlock() }
    func release(_ id: String) { lock.lock(); if let fd = fds.removeValue(forKey: id) { close(fd) }; lock.unlock() }
}
let live = LiveDispatches()

//: @use-case:host.conformance.harness_accepts_and_calls_the_contract
let server = Server(name: "cowork", version: coworkVersion,
                    capabilities: .init(tools: .init(listChanged: false)))
//: @use-case:end host.conformance.harness_accepts_and_calls_the_contract

/// A JSON-Schema string property. A tool's inputSchema must be a real JSON Schema:
/// the top level is `{"type":"object","properties":{…}}` and every property is
/// itself a schema object, not a bare description string. A strict MCP host
/// Code) rejects the whole tool list otherwise — proven live against a strict MCP host.
@Sendable func strProp(_ description: String) -> Value {
    .object(["type": .string("string"), "description": .string(description)])
}

// Roles are additive sugar (ADR 002): each .role file becomes one `role_*` tool on top
// of the 10 core tools (ADR 001). Discovery is THREE layers sharing one namespace,
// most-specific wins — override is a feature, mirroring ADR 005's config precedence:
//
//   shipped   cowork's own roles/ (found beside the installed binary)
//   global    ~/.cowork/roles           ($COWORK_ROLES overrides, for tests)
//   project   <cwd>/.cowork/roles       (the team's, cloned with the repo)
//
// A project role with a shipped role's NAME replaces it under the same stable tool
// name, so skills that call `role_review_security` automatically get the project's
// customisation. The shadowing is visible, never silent: origin is tagged in the tool
// description and an override is named there too. A project role is untrusted prompt
// content (ADR 005) — it can name no credential and run no code, and the composed task
// stays inspectable — so origin-reporting is the honest mitigation, not a block.
//
// Live reload: layers are re-read on every `tools/list` and every `role_*` call, so
// editing, adding, or removing a role file takes effect on the next request with no
// restart. `listChanged` stays unadvertised: without a file watcher cowork sends no
// notification, and a capability it does not honour would be comfort, not fact.

/// The roles cowork ships, found by walking up from the real binary (works from
/// `.build/release/cowork` in the repo and from an installed copy beside a `roles/`
/// dir). `$COWORK_SHIPPED_ROLES` overrides; nil when nothing is found.
func shippedRolesDirectory() -> URL? {
    if let env = ProcessInfo.processInfo.environment["COWORK_SHIPPED_ROLES"] {
        return env.isEmpty ? nil : URL(fileURLWithPath: env)
    }
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent()
    for _ in 0..<5 {
        let candidate = dir.appendingPathComponent("roles")
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: candidate.path),
           entries.contains(where: { $0.hasSuffix(".role") }) {
            return candidate
        }
        dir.deleteLastPathComponent()
    }
    return nil
}

let shippedRoles = shippedRolesDirectory()
let globalRoles = ProcessInfo.processInfo.environment["COWORK_ROLES"].map(URL.init(fileURLWithPath:))
    ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cowork/roles")
let projectRoles = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(".cowork/roles")

@Sendable func currentRoles() -> RoleLibrary.Resolved {
    let resolved = RoleLibrary.resolve(shipped: shippedRoles, global: globalRoles,
                                       project: projectRoles)
    // An unreadable/invalid role is surfaced with its layer, never silently dropped.
    for bad in resolved.unreadable {
        FileHandle.standardError.write(
            Data("cowork: \(bad.diagnostic) (\(bad.origin.rawValue): \(bad.file))\n".utf8))
    }
    return resolved
}

// One role tool per resolved role: the caller supplies backend/workspace/interactive
// plus the role's declared slots; the role owns the task's structure. Origin and any
// override are part of the description — visible where a caller chooses tools.
@Sendable func roleTool(for resolved: RoleLibrary.ResolvedRole) -> Tool {
    let role = resolved.role
    var props: [String: Value] = [
        "backend": strProp("Configured backend id"),
        "workspace": strProp("Directory the worker may work in. Omit for unconfined."),
        "interactive": strProp("'true' keeps the worker warm for send/finish. Defaults to false."),
    ]
    for slot in role.slots { props[slot] = strProp("Role slot (required): \(slot)") }
    var description = role.description
    if resolved.origin != .shipped { description = "[\(resolved.origin.rawValue)] " + description }
    if !resolved.overrides.isEmpty {
        let shadowed = resolved.overrides.map(\.rawValue).joined(separator: ", ")
        description += " (overrides the \(shadowed) role)"
    }
    return Tool(name: "role_\(role.name)", description: description,
                inputSchema: .object(["type": .string("object"), "properties": .object(props)]))
}

/// Start a dispatch from an already-composed task, shared by `dispatch` and every
/// `role_*` tool so the role path is exactly the core path with a pre-composed task.
@Sendable func startDispatch(task: String, arguments: [String: Value]?) -> CallTool.Result {
    guard case let .string(backendID)? = arguments?["backend"] else {
        return .init(content: [.text("missing backend")], isError: true)
    }
    guard let resolved = resolveBackend(backendID), resolved.oneShot(DispatchContext()) != nil else {
        return .init(content: [.text("no such backend '\(backendID)'. visible providers: "
                                     + config.visible.keys.sorted().joined(separator: ", ")
                                     + "; cli: " + config.cli.keys.sorted().joined(separator: ", "))],
                     isError: true)
    }
    var workspacePath: String? = nil
    if case let .string(p)? = arguments?["workspace"] { workspacePath = p }
    var interactive = false
    if case let .string(flag)? = arguments?["interactive"] { interactive = flag == "true" }
    // The teardown hook (ADR 002 rule 9) is public because sugar may only use the
    // core's public tools (rule 2) — an in-process-only hook would dissolve the layering.
    var onTerminal: String? = nil
    if case let .string(cmd)? = arguments?["on_terminal"] { onTerminal = cmd }
    do {
        let started = try dispatcher.start(task: task, backend: backendID,
                                           workspace: workspacePath,
                                           parent: Lineage.parent, root: Lineage.root,
                                           interactive: interactive, onTerminal: onTerminal)
        live.keep(started.id, started.deathPipeWriteEnd)
        return .init(content: [.text(started.id)])
    } catch {
        return .init(content: [.text("dispatch failed: \(error)")], isError: true)
    }
}

//: @use-case:contract.tools.ten_tools_exposed#ten_tools_exposed
await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: currentRoles().roles.map(roleTool) + [
        Tool(name: "dispatch",
             description: "Dispatch work to an agent. Returns a dispatch id immediately; "
                 + "the work runs on independently and durably. To collect the result, prefer "
                 + "in order: (1) let your harness background a blocking `wait` if it can — "
                 + "it frees your turn; (2) otherwise poll `status`/`output` (the durable "
                 + "monitor — the event stream is also tail-able); (3) otherwise call `wait` "
                 + "with a timeout. All three read the same durable record.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
                 "task": strProp("The work to do"),
                 "backend": strProp("Configured backend id"),
                 "workspace": strProp("Directory the worker may work in. Omit for unconfined."),
                 "interactive": strProp("'true' keeps the worker warm for send/finish. Defaults to false."),
                 "on_terminal": strProp("Command run by the supervisor when the dispatch SUCCEEDS (teardown). Failed/cancelled dispatches keep their workspace."),
             ])])),
        Tool(name: "status",
             description: "Current lifecycle state and truthful diagnostics for a dispatch.",
             inputSchema: .object(["type": .string("object"), "properties": .object(["id": strProp("Dispatch id")])])),
        Tool(name: "output",
             description: "The worker's declared result for a dispatch.",
             inputSchema: .object(["type": .string("object"), "properties": .object(["id": strProp("Dispatch id")])])),
        Tool(name: "wait",
             description: "Block up to a hard-capped timeout, then return the state, including "
                 + "'still running'. Send a progressToken to receive notifications/progress "
                 + "heartbeats carrying the live lifecycle state while it blocks (visibility "
                 + "only — the terminal result is identical without one).",
             inputSchema: .object(["type": .string("object"), "properties": .object([
                 "id": strProp("Dispatch id"),
                 "timeout": strProp("Seconds, hard-capped"),
             ])])),
        Tool(name: "cancel",
             description: "Stop a dispatch and its worker.",
             inputSchema: .object(["type": .string("object"), "properties": .object(["id": strProp("Dispatch id")])])),
        Tool(name: "list",
             description: "Dispatches and their states. Scoped to the caller's own lineage by default; 'all' for everything on the machine.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
                 "scope": strProp("Omit for your own lineage, or 'all'"),
             ])])),
        Tool(name: "send",
             description: "Send a message to a live worker. Requires capabilities.supports_message.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
                 "id": strProp("Dispatch id"),
                 "message": strProp("What to tell the worker"),
             ])])),
        Tool(name: "finish",
             description: "End an interactive dispatch and release its worker.",
             inputSchema: .object(["type": .string("object"), "properties": .object(["id": strProp("Dispatch id")])])),
        Tool(name: "follow_up",
             description: "New dispatch carrying a finished dispatch's context. Inherits backend and workspace. Requires capabilities.supports_follow_up.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
                 "id": strProp("The finished dispatch to continue"),
                 "task": strProp("What to do next"),
             ])])),
        Tool(name: "capabilities",
             description: "Truthful facts about backends, including live availability.",
             inputSchema: .object(["type": .string("object"), "properties": .object([
                 "backend": strProp("Omit for everything visible, or a provider / provider/model / cli name"),
             ])])),
    ])
//: @use-case:end contract.tools.ten_tools_exposed#ten_tools_exposed
}

await server.withMethodHandler(CallTool.self) { params in
    switch params.name {
//: @use-case:host.conformance.dispatch_roundtrip_through_the_harness
    case "dispatch":
        guard case let .string(task)? = params.arguments?["task"]
        else { return .init(content: [.text("missing task or backend")], isError: true) }
//: @use-case:end host.conformance.dispatch_roundtrip_through_the_harness
        // Spawn a supervisor and return an id; the work happens in that process, which
        // is what makes status, wait, cancel and send real (ADR 001, ADR 003 rule 1).
        return startDispatch(task: task, arguments: params.arguments)

    case "status":
        guard case let .string(id)? = params.arguments?["id"]
        else { return .init(content: [.text("unknown dispatch")], isError: true) }
        let r: DispatchRecord
        switch DispatchRecord.loadResult(id) {
        case let .loaded(record):
            r = record
        case .missing:
            return .init(content: [.text("unknown dispatch")], isError: true)
        case .unreadable:
            return .init(content: [.text("status.unreadable-record,id=\(id)")], isError: true)
        }
        let diag = r.diagnostics.isEmpty ? "" : " diagnostics=\(r.diagnostics.joined(separator: ","))"
        return .init(content: [.text("\(r.state.rawValue)\(diag)")])

    case "wait":
        guard case let .string(id)? = params.arguments?["id"]
        else { return .init(content: [.text("missing id")], isError: true) }
        var timeout: TimeInterval = 30
        if case let .string(raw)? = params.arguments?["timeout"], let parsed = TimeInterval(raw) {
            timeout = parsed
        }
        // A caller that sent a progressToken gets a heartbeat while the wait blocks:
        // one notifications/progress per poll carrying the live lifecycle state. This
        // is pure visibility — the same record status/output read, the same terminal
        // result — so a host that ignores or cannot render progress loses nothing.
        let record: DispatchRecord?
        if let token = params._meta?.progressToken {
            record = await WaitProgress.run(
                id: id, timeout: timeout,
                load: { DispatchRecord.load($0) },
                emit: { emission in
                    try? await server.notify(ProgressNotification.message(.init(
                        progressToken: token, progress: emission.progress,
                        total: nil, message: emission.message)))
                },
                sleep: { try? await Task.sleep(nanoseconds: 200_000_000) },
                now: { Date() })
        } else {
            record = dispatcher.wait(id: id, timeout: timeout)
        }
        guard let r = record else {
            return .init(content: [.text("unknown dispatch")], isError: true)
        }
        return .init(content: [.text(r.state.rawValue)])

    case "cancel":
        guard case let .string(id)? = params.arguments?["id"]
        else { return .init(content: [.text("missing id")], isError: true) }
        guard dispatcher.cancel(id: id) else {
            return .init(content: [.text("unknown dispatch")], isError: true)
        }
        live.release(id)
        return .init(content: [.text(DispatchRecord.load(id)?.state.rawValue ?? "cancelled")])

    case "list":
        var raw: String? = nil
        if case let .string(s)? = params.arguments?["scope"] { raw = s }
        // A scope cowork cannot honour is refused rather than silently becoming a
        // different scope — a caller must never be shown someone else's work, nor
        // silently denied their own.
        guard let scope = ListScope.parse(raw) else {
            return .init(content: [.text("unknown scope '\(raw ?? "")'; omit for your own lineage, or 'all'")],
                         isError: true)
        }
        let listed = DispatchList.list(scope: scope)
        let rows = listed.dispatches.map {
            "\($0.state.rawValue)\t\($0.id)\t\($0.backend)\tparent=\($0.parent)\troot=\($0.root)"
        // An unreadable record must stay visible here: dropping it would reintroduce
        // exactly the silence the separate field exists to prevent.
        } + listed.unreadable.map { "unreadable\t\($0.id)\t\($0.diagnostic)" }
        return .init(content: [.text(rows.isEmpty ? "(no dispatches)" : rows.joined(separator: "\n"))])

    case "send":
        guard case let .string(id)? = params.arguments?["id"],
              case let .string(message)? = params.arguments?["message"]
        else { return .init(content: [.text("missing id or message")], isError: true) }
        do {
            // Whether a backend can be messaged is the resolved backend's real
            // interactive operation — not mere existence of a config entry
            // (ADR 001 rule 3). Existence alone once left send dead under a green
            // contract when capability and check disagreed.
            try Interaction.send(id: id, message: message) { backend in
                resolveBackend(backend)?.supportsMessage == true
            }
            return .init(content: [.text("sent")])
        } catch let e as Interaction.Failure {
            return .init(content: [.text(e.description)], isError: true)
        } catch {
            return .init(content: [.text("send failed: \(error)")], isError: true)
        }

    case "finish":
        guard case let .string(id)? = params.arguments?["id"]
        else { return .init(content: [.text("missing id")], isError: true) }
        do {
            let state = try Interaction.finish(id: id)
            live.release(id)
            return .init(content: [.text(state.rawValue)])
        } catch let e as Interaction.Failure {
            return .init(content: [.text(e.description)], isError: true)
        } catch {
            return .init(content: [.text("finish failed: \(error)")], isError: true)
        }

    case "follow_up":
        guard case let .string(id)? = params.arguments?["id"],
              case let .string(task)? = params.arguments?["task"]
        else { return .init(content: [.text("missing id or task")], isError: true) }
        do {
            // Everything but the task is inherited: a caller who could re-supply
            // the backend or workspace could differ, and a follow-up whose
            // workspace differs is not a follow-up.
            let plan = try FollowUp.plan(from: id, task: task)
            let started = try dispatcher.start(task: plan.task, backend: plan.backend,
                                               workspace: plan.workspace,
                                               parent: plan.parent, root: plan.root,
                                               continues: plan.continuation)
            live.keep(started.id, started.deathPipeWriteEnd)
            return .init(content: [.text(started.id)])
        } catch let e as FollowUp.Failure {
            return .init(content: [.text(e.description)], isError: true)
        } catch {
            return .init(content: [.text("follow_up failed: \(error)")], isError: true)
        }

    case "capabilities":
        var backend: String? = nil
        if case let .string(b)? = params.arguments?["backend"] { backend = b }
        do {
            let facts = try await Capabilities.facts(backend: backend, config: config)
            let rows = facts.map { f in
                "\(f.available ? "available" : "unavailable")\t\(f.id)\t\(f.kind.rawValue)"
                    + "\torigin=\(f.origin.rawValue)"
                    + "\tmessage=\(f.supportsMessage)\tfollow_up=\(f.supportsFollowUp)"
                    + (f.diagnostics.isEmpty ? "" : "\t\(f.diagnostics.joined(separator: ","))")
            }
            return .init(content: [.text(rows.isEmpty ? "(no backends visible)" : rows.joined(separator: "\n"))])
        } catch let e as CapabilitiesError {
            return .init(content: [.text(e.description)], isError: true)
        } catch {
            return .init(content: [.text("capabilities failed: \(error)")], isError: true)
        }

    case "output":
        guard case let .string(id)? = params.arguments?["id"]
        else { return .init(content: [.text("unknown dispatch")], isError: true) }
        let r: DispatchRecord
        switch DispatchRecord.loadResult(id) {
        case let .loaded(record):
            r = record
        case .missing:
            return .init(content: [.text("unknown dispatch")], isError: true)
        case .unreadable:
            return .init(content: [.text("output.unreadable-record,id=\(id)")], isError: true)
        }
        return .init(content: [.text(r.result ?? "")])

    default:
        // Role tools (ADR 002): compose the role's template from its declared slots,
        // then take exactly the core dispatch path with the pre-composed task. The
        // composed task is the dispatch record's task — inspectable in the record
        // (rule 6), never a prompt cowork hides.
        if params.name.hasPrefix("role_"),
           let role = currentRoles().roles
               .first(where: { $0.role.name == String(params.name.dropFirst("role_".count)) })?.role {
            var values: [String: String] = [:]
            for slot in role.slots {
                guard case let .string(v)? = params.arguments?[slot] else {
                    return .init(content: [.text("role_\(role.name): missing slot '\(slot)'")], isError: true)
                }
                values[slot] = v
            }
            let composed: String
            do { composed = try role.compose(values) }
            catch { return .init(content: [.text("role_\(role.name): \(error)")], isError: true) }

            // workspace: "worktree" is SUGAR (ADR 002 rule 8): provision a sibling
            // worktree here, hand the core a plain path, and pass the removal as
            // on_terminal — which the core runs on success only (rule 10), so a
            // failed dispatch's worktree is kept as evidence for free. The core
            // never learns what git is; plain `dispatch` has no such keyword.
            var arguments = params.arguments ?? [:]
            if case .string("worktree")? = arguments["workspace"] {
                let probe = Process()
                probe.executableURL = URL(fileURLWithPath: "/bin/sh")
                probe.arguments = ["-c", "git rev-parse --show-toplevel"]
                let out = Pipe(); probe.standardOutput = out; probe.standardError = Pipe()
                guard (try? probe.run()) != nil else {
                    return .init(content: [.text("role.worktree-unavailable: cannot run git")], isError: true)
                }
                probe.waitUntilExit()
                let root = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard probe.terminationStatus == 0, !root.isEmpty else {
                    return .init(content: [.text("role.worktree-unavailable: not inside a git repository")],
                                 isError: true)
                }
                let plan = WorktreeProvision.plan(repoRoot: URL(fileURLWithPath: root),
                                                  suffix: String(UUID().uuidString.prefix(8)).lowercased())
                let create = Process()
                create.executableURL = URL(fileURLWithPath: "/bin/sh")
                create.arguments = ["-c", plan.createCommand]
                create.standardOutput = Pipe(); create.standardError = Pipe()
                guard (try? create.run()) != nil else {
                    return .init(content: [.text("role.worktree-failed: cannot run git")], isError: true)
                }
                create.waitUntilExit()
                guard create.terminationStatus == 0 else {
                    return .init(content: [.text("role.worktree-failed: exit=\(create.terminationStatus)")],
                                 isError: true)
                }
                arguments["workspace"] = .string(plan.path)
                // A caller-supplied on_terminal still runs; the teardown follows it.
                if case let .string(existing)? = arguments["on_terminal"] {
                    arguments["on_terminal"] = .string(existing + " ; " + plan.teardownCommand)
                } else {
                    arguments["on_terminal"] = .string(plan.teardownCommand)
                }
            }
            return startDispatch(task: composed, arguments: arguments)
        }
        return .init(content: [.text("unknown tool '\(params.name)'")], isError: true)
    }
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
