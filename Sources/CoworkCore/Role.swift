import Foundation

/// A role: opinionated, customisable sugar defined by a file, not code (ADR 002).
///
/// The file is self-contained (the format the user agreed): TOML front-matter —
/// `name`, `description`, and the declared `slots` — then a `---` line, then the
/// template body. It surfaces as one additive, `role_`-namespaced tool (ADR 001),
/// and its slots are **hard edges**: composition rejects a missing slot, an unknown
/// slot, and — at parse time — a template that references a slot it never declared.
/// A slot that accepts anything guarantees nothing.
public struct Role: Equatable, Sendable {
    public let name: String
    public let description: String
    /// Declared injection points, in the order the file lists them.
    public let slots: [String]
    /// The template body verbatim, with `{slot}` placeholders still in place.
    public let template: String

    public enum ParseError: Error, Equatable {
        case missingSeparator
        case frontMatter(String)
        case missingName
        case missingDescription
        case undeclaredPlaceholder(String)
    }

    public enum ComposeError: Error, Equatable {
        case missingSlot(String)
        case unknownSlot(String)
    }

    public init(name: String, description: String, slots: [String], template: String) {
        self.name = name
        self.description = description
        self.slots = slots
        self.template = template
    }

    /// Parse a role file: front-matter, `---`, body. The separator is the first line
    /// that is exactly `---`, so a `---` inside the body is left untouched.
//: @use-case:sugar.roles.malformed_role_is_refused_by_name
    public static func parse(_ text: String) throws -> Role {
        let lines = text.components(separatedBy: "\n")
        guard let sep = lines.firstIndex(of: "---") else { throw ParseError.missingSeparator }

        let front = lines[..<sep].joined(separator: "\n")
        let template = lines[(sep + 1)...].joined(separator: "\n")

        let doc: [String: Any]
        do {
            doc = try Toml.parse(front)
        } catch {
            throw ParseError.frontMatter("\(error)")
        }

        guard let name = doc["name"] as? String, !name.isEmpty else { throw ParseError.missingName }
        guard let description = doc["description"] as? String, !description.isEmpty else {
            throw ParseError.missingDescription
        }
        let slots = (doc["slots"] as? [Any])?.compactMap { $0 as? String } ?? []

        // A template may only reference slots it declares — a `{foo}` with no `foo`
        // slot is a role that can never be filled correctly, so it is refused now
        // rather than surfacing an empty hole at dispatch time.
        for placeholder in placeholders(in: template) where !slots.contains(placeholder) {
            throw ParseError.undeclaredPlaceholder(placeholder)
        }

        return Role(name: name, description: description, slots: slots, template: template)
    }
//: @use-case:end sugar.roles.malformed_role_is_refused_by_name

    /// Fill the template from `values`, enforcing the hard edges: every declared slot
    /// must be supplied, and every supplied value must be a declared slot. A slot's
    /// value is inserted verbatim — brace-like text inside a value is NOT re-expanded,
    /// so a caller cannot smuggle a second substitution through a value.
//: @use-case:sugar.roles.role_tool_composes_and_dispatches#role_tool_composes_and_di
    public func compose(_ values: [String: String]) throws -> String {
        for slot in slots where values[slot] == nil { throw ComposeError.missingSlot(slot) }
        for key in values.keys where !slots.contains(key) { throw ComposeError.unknownSlot(key) }

        // Single left-to-right pass so an inserted value is never re-scanned for
        // placeholders (verbatim insertion).
        var result = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            result += rest[..<open]
            let afterOpen = rest.index(after: open)
            if let close = rest[afterOpen...].firstIndex(of: "}") {
                let token = String(rest[afterOpen..<close])
                if let value = values[token] {
                    result += value
                    rest = rest[rest.index(after: close)...]
                    continue
                }
                // Not a known slot (parse guaranteed every placeholder is declared, so
                // this is stray literal text like `{}` or `{ ... }`): keep the brace
                // verbatim and continue past it.
            }
            result += "{"
            rest = rest[afterOpen...]
        }
        result += rest
        return result
    }
//: @use-case:end sugar.roles.role_tool_composes_and_dispatches#role_tool_composes_and_di

    /// The `{slot}` identifiers a template references — word-shaped only, so `{}` or
    /// `{ spaces }` are literal text, never slots.
    private static func placeholders(in template: String) -> [String] {
        var found: [String] = []
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: "}") else { break }
            let token = String(rest[afterOpen..<close])
            if isIdentifier(token) { found.append(token) }
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    private static func isIdentifier(_ s: String) -> Bool {
        guard let first = s.first, first == "_" || first.isLetter else { return false }
        return s.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }
}

/// The roles on disk: each `.role` file becomes a `Role`, and an unreadable one is
/// surfaced by name rather than silently dropped — a broken role a user is trying to
/// use must be visible, exactly as an unreadable dispatch record is (ADR 000).
public enum RoleLibrary {
    public struct Unreadable: Equatable, Sendable {
        public let file: String
        public let diagnostic: String
    }

    public struct Loaded: Equatable, Sendable {
        public let roles: [Role]
        public let unreadable: [Unreadable]
    }

    public static func load(from directory: URL) -> Loaded {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return Loaded(roles: [], unreadable: [])
        }
        var roles: [Role] = []
        var unreadable: [Unreadable] = []
        for file in entries.sorted() where file.hasSuffix(".role") {
            let url = directory.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                unreadable.append(Unreadable(file: file, diagnostic: "role.unreadable"))
                continue
            }
            do {
                roles.append(try Role.parse(text))
            } catch {
                unreadable.append(Unreadable(file: file, diagnostic: "role.invalid: \(error)"))
            }
        }
        return Loaded(roles: roles, unreadable: unreadable)
    }

    // MARK: layering — shipped ∪ global ∪ project, most-specific wins

    /// Where a role came from, most general to most specific. The order IS the
    /// precedence: a later layer's role replaces an earlier one with the same name.
    public enum RoleOrigin: String, Sendable, CaseIterable {
        case shipped   // cowork's own roles, installed with the plugin
        case global    // the user's ~/.cowork/roles — theirs, across every project
        case project   // <repo>/.cowork/roles — the team's, cloned with the repo
    }

    /// One role after layering: which layer won, and which layers it shadowed.
    /// Override is a *feature* — a project customises a shipped role under the same
    /// stable tool name so callers substitute automatically — and it is *visible*:
    /// the shadowed origins are recorded, never silently dropped (ADR 000).
    public struct ResolvedRole: Equatable, Sendable {
        public let role: Role
        public let origin: RoleOrigin
        /// Origins this role shadowed, most general first. Empty when nothing was.
        public let overrides: [RoleOrigin]
    }

    public struct UnreadableInLayer: Equatable, Sendable {
        public let origin: RoleOrigin
        public let file: String
        public let diagnostic: String
    }

    public struct Resolved: Equatable, Sendable {
        public let roles: [ResolvedRole]
        public let unreadable: [UnreadableInLayer]
    }

    /// Resolve the three layers into one namespace. Identity is the role's declared
    /// `name` (the tool is `role_<name>`), not its filename — mirroring ADR 005's
    /// config precedence (project over global), with origin reported rather than
    /// names mangled per scope, so callers keep one stable name per role.
    public static func resolve(shipped: URL?, global globalDir: URL?, project: URL?) -> Resolved {
        var byName: [String: ResolvedRole] = [:]
        var order: [String] = []
        var unreadable: [UnreadableInLayer] = []

        // The flat install layout puts the shipped roles AT the global layer's
        // path (~/.cowork/roles). One directory is one layer: reading it twice
        // would report every shipped role as global-shadowing-shipped — noise
        // for an override that never happened.
        let global = (globalDir?.standardizedFileURL.path == shipped?.standardizedFileURL.path)
            ? nil : globalDir
        let layers: [(RoleOrigin, URL?)] = [(.shipped, shipped), (.global, global), (.project, project)]
        for (origin, directory) in layers {
            guard let directory else { continue }
            let loaded = load(from: directory)
            unreadable += loaded.unreadable.map {
                UnreadableInLayer(origin: origin, file: $0.file, diagnostic: $0.diagnostic)
            }
            for role in loaded.roles {
                if let shadowed = byName[role.name] {
                    byName[role.name] = ResolvedRole(role: role, origin: origin,
                                                     overrides: shadowed.overrides + [shadowed.origin])
                } else {
                    byName[role.name] = ResolvedRole(role: role, origin: origin, overrides: [])
                    order.append(role.name)
                }
            }
        }
        return Resolved(roles: order.compactMap { byName[$0] }, unreadable: unreadable)
    }
}
