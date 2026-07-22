import Foundation

/// The tools cowork offers a model endpoint.
///
/// For an endpoint backend the model runs elsewhere and *cowork* executes the
/// tools, so confinement here is a property of this code rather than of the OS
/// (ADR 002). A workspace grant is enforced by refusing the call, and the refusal
/// is returned to the model as a tool result: the model learns it may not go
/// there, rather than cowork silently doing something else.
public struct Workspace {
    public let root: URL
    public let writable: Bool

    public init(root: URL, writable: Bool) {
        self.root = root
        self.writable = writable
    }

    /// Resolve a model-supplied path against the grant.
    ///
    /// Canonicalises before comparing, so `../` and symlinks cannot walk out. A
    /// path outside the grant is an error, never a clamp: silently rewriting a
    /// path the model asked for would be the same class of lie as misreporting an
    /// outcome.
    public func resolve(_ path: String) throws -> URL {
        let candidate = path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : root.appendingPathComponent(path)
        let real = URL(fileURLWithPath: (candidate.path as NSString).standardizingPath)
        let rootReal = URL(fileURLWithPath: (root.path as NSString).standardizingPath)
        guard real.path == rootReal.path || real.path.hasPrefix(rootReal.path + "/") else {
            throw ToolError.outsideWorkspace(real.path, rootReal.path)
        }
        return real
    }
}

public enum ToolError: Error, CustomStringConvertible {
    case outsideWorkspace(String, String)
    case notWritable
    case io(String)

    public var description: String {
        switch self {
        case let .outsideWorkspace(p, root): return "denied: \(p) is outside the workspace grant (\(root))"
        case .notWritable: return "denied: this dispatch has a read-only workspace grant"
        case let .io(m): return "error: \(m)"
        }
    }
}

public enum Tools {
    /// Declared to the endpoint in its own native dialect. Cowork does not invent
    /// a tool protocol; it speaks the one the endpoint already implements.
    public static func definitions() -> [EndpointTool] {
        [
            fn("read_file", "Read a UTF-8 text file from the workspace",
               ["path": ["type": "string", "description": "Path within the workspace"]], ["path"]),
            fn("write_file", "Write a UTF-8 text file into the workspace",
               ["path": ["type": "string", "description": "Path within the workspace"],
                "content": ["type": "string", "description": "Full file contents"]], ["path", "content"]),
            fn("list_dir", "List entries of a directory in the workspace",
               ["path": ["type": "string", "description": "Path within the workspace"]], ["path"]),
        ]
    }

    private static func fn(_ name: String, _ desc: String,
                           _ props: [String: Any], _ required: [String]) -> EndpointTool {
        EndpointTool(name: name, description: desc,
                     inputSchema: ["type": "object", "properties": props, "required": required])
    }

    /// Execute a tool call. Every failure is returned to the model as text, so the
    /// loop stays truthful: the model is told exactly what happened rather than
    /// being handed a fabricated success.
//: @use-case:endpoint.tool_loop.model_uses_workspace_tools#model_uses_workspace_too
    public static func execute(name: String, arguments: String, workspace: Workspace?) -> String {
        guard let ws = workspace else {
            return "denied: this dispatch has no workspace grant, so file tools are unavailable"
        }
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "error: could not parse tool arguments" }

        do {
            switch name {
            case "read_file":
                guard let p = args["path"] as? String else { return "error: missing path" }
                let url = try ws.resolve(p)
                return try String(contentsOf: url, encoding: .utf8)

            case "write_file":
                guard ws.writable else { throw ToolError.notWritable }
                guard let p = args["path"] as? String, let c = args["content"] as? String
                else { return "error: missing path or content" }
                let url = try ws.resolve(p)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try c.write(to: url, atomically: true, encoding: .utf8)
                return "wrote \(c.utf8.count) bytes to \(url.lastPathComponent)"

            case "list_dir":
                guard let p = args["path"] as? String else { return "error: missing path" }
                let url = try ws.resolve(p)
                let items = try FileManager.default.contentsOfDirectory(atPath: url.path)
                return items.isEmpty ? "(empty)" : items.sorted().joined(separator: "\n")

            default:
                return "error: unknown tool \(name)"
            }
        } catch let e as ToolError {
            return e.description
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }
}
