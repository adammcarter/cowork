import Foundation

/// A deliberately small TOML reader for cowork's own config shape.
///
/// Not a general TOML implementation, and not trying to be. ADR 004 records that
/// the cheapest move in this ecosystem is to add a dependency, and that every
/// dependency is surface area in a tool that runs other agents against a user's
/// workspace. Config is a handful of tables of strings and string arrays; that is
/// worth ~80 lines to avoid a supply chain.
///
/// Supported, because it is all cowork's config uses: `[table.sub]` headers,
/// `key = "string"`, `key = ["a", "b"]`, inline `{ k = "v" }` tables, `#` comments.
enum Toml {
    static func parse(contentsOf url: URL, required: Bool) throws -> [String: Any] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            if required { throw ConfigError.unreadable(url.path) }
            return [:]
        }
        return try parse(text)
    }

    static func parse(_ text: String) throws -> [String: Any] {
        var root: [String: Any] = [:]
        var path: [String] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = strip(String(raw))
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                guard line.hasSuffix("]") else { throw ConfigError.malformed(line) }
                path = String(line.dropFirst().dropLast())
                    .split(separator: ".")
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                continue
            }

            guard let eq = line.firstIndex(of: "=") else { throw ConfigError.malformed(line) }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let rhs = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            insert(value(rhs), at: path + [key], into: &root)
        }
        return root
    }

    /// All immediate subtables under a prefix: `provider` -> ["omlx": [...], ...].
    static func subtables(of doc: [String: Any], prefix: String) -> [String: [String: Any]] {
        guard let table = doc[prefix] as? [String: Any] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for (name, value) in table {
            if let sub = value as? [String: Any] { out[name] = sub }
        }
        return out
    }

    private static func strip(_ line: String) -> String {
        var out = ""
        var inString = false
        for c in line {
            if c == "\"" { inString.toggle() }
            if c == "#", !inString { break }
            out.append(c)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func value(_ raw: String) -> Any {
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            return String(raw.dropFirst().dropLast())
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                .filter { !$0.isEmpty }
        }
        if raw.hasPrefix("{") && raw.hasSuffix("}") {
            var inline: [String: Any] = [:]
            for pair in splitInline(String(raw.dropFirst().dropLast())) {
                guard let eq = pair.firstIndex(of: "=") else { continue }
                let k = String(pair[pair.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(pair[pair.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                inline[k] = value(v)
            }
            return inline
        }
        if raw.hasPrefix("\"") && raw.hasSuffix("\"") && raw.count >= 2 {
            return String(raw.dropFirst().dropLast())
        }
        if raw == "true" { return true }
        if raw == "false" { return false }
        if let i = Int(raw) { return i }
        return raw
    }

    /// Split on commas that are not inside a quoted string.
    private static func splitInline(_ body: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inString = false
        for c in body {
            if c == "\"" { inString.toggle() }
            if c == ",", !inString { parts.append(current); current = ""; continue }
            current.append(c)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { parts.append(current) }
        return parts
    }

    private static func insert(_ value: Any, at path: [String], into doc: inout [String: Any]) {
        guard let head = path.first else { return }
        if path.count == 1 { doc[head] = value; return }
        var child = doc[head] as? [String: Any] ?? [:]
        insert(value, at: Array(path.dropFirst()), into: &child)
        doc[head] = child
    }
}
