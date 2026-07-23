import Foundation

/// A provider credential.
///
/// The rule (ADR 000): a credential never reaches a child's argv or environment,
/// a log, a record, an event, a diagnostic, or a transcript. The type enforces
/// that rather than trusting a reviewer to notice — `Debug` is redacted by hand,
/// there is no `Codable` conformance, and the value is reachable only through a
/// single explicit accessor used at the one point of use.
public struct Credential: Sendable, CustomStringConvertible, CustomDebugStringConvertible,
                          CustomReflectable {
    private let value: String

    public init(_ value: String) { self.value = value }

    /// The only way out. Named so that any other use reads as a mistake.
    public func exposeForAuthorizationHeader() -> String { value }

    public var description: String { "<redacted credential>" }
    public var debugDescription: String { "<redacted credential>" }

    /// Redacting the string conversions is not enough, and a test caught this
    /// printing the key in full.
    ///
    /// `dump()`, `Mirror`, and anything else reflective walks *stored properties*
    /// — none of them call `description`. So a type that overrode only the string
    /// conversions still hands its secret to any diagnostic dump, which is exactly
    /// the well-meaning debugging line that ships. Reflection is a way out of the
    /// type, so it is closed at the type rather than by asking people to remember.
    public var customMirror: Mirror {
        Mirror(self, children: ["value": "<redacted credential>"])
    }
}

public enum Secrets {
    /// Reads an environment variable — from the process environment, or from a
    /// `.env` file beside the current working directory — as the supported source
    /// of a provider credential. It is fetched through this single seam, rather
    /// than read inline at the call site, so the value reaches exactly one point
    /// of use.
//: @use-case:endpoint.credential.absent_names_the_variable_never_a_value#absent_names_the_variabl
    public static func load(_ name: String) -> Credential? {
        if let v = ProcessInfo.processInfo.environment[name], !v.isEmpty {
            return Credential(v)
        }
        let env = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".env")
        guard let text = try? String(contentsOf: env, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { continue }
            let k = String(t[t.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let v = String(t[t.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if k == name, !v.isEmpty { return Credential(v) }
        }
        return nil
    }
}
