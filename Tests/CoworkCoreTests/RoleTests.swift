import Foundation
import Testing

@testable import CoworkCore

/// A role is data, not code (ADR 002): a self-contained file — TOML front-matter
/// (name, description, declared slots) then `---` then a template body. It becomes
/// one additive, namespaced `role_*` tool (ADR 001), and its slots are HARD edges:
/// a slot that accepts anything guarantees nothing, so composition rejects a missing
/// slot, an unknown slot, and a template that references an undeclared one.
@Suite("Role — data, with hard slot edges")
struct RoleTests {
    private let planImplementer = """
    name = "plan_implementer"
    description = "Work a plan step by step, marking progress."
    slots = ["plan", "constraints"]
    ---
    You are implementing this plan:
    {plan}

    Constraints: {constraints}
    """

    // MARK: parsing — a role is a file

    @Test("a well-formed role parses into name, description, ordered slots, and template")
    func parsesWellFormed() throws {
        let role = try Role.parse(planImplementer)
        #expect(role.name == "plan_implementer")
        #expect(role.description == "Work a plan step by step, marking progress.")
        #expect(role.slots == ["plan", "constraints"])
        #expect(role.template.contains("{plan}"))
        #expect(role.template.hasPrefix("You are implementing"))
    }

    @Test("front matter and template are split on the first --- only")
    func splitsOnFirstSeparator() throws {
        let role = try Role.parse("""
        name = "r"
        description = "d"
        slots = []
        ---
        body line 1
        ---
        body line 2
        """)
        #expect(role.template == "body line 1\n---\nbody line 2")
    }

    @Test("a role with no --- separator is a named parse failure, not a guess")
    func missingSeparatorFails() {
        #expect(throws: Role.ParseError.self) {
            try Role.parse("name = \"r\"\ndescription = \"d\"\nslots = []")
        }
    }

    @Test("a role missing its name or description is refused")
    func missingRequiredFieldFails() {
        #expect(throws: Role.ParseError.self) {
            try Role.parse("description = \"d\"\nslots = []\n---\nbody")
        }
        #expect(throws: Role.ParseError.self) {
            try Role.parse("name = \"r\"\nslots = []\n---\nbody")
        }
    }

    /// The load-bearing parse rule: a template may only reference slots it declares.
    /// A `{foo}` with no `foo` slot is a role that can never be filled correctly.
    @Test("a template referencing an undeclared slot is refused at parse time")
    func undeclaredPlaceholderFails() {
        #expect(throws: Role.ParseError.self) {
            try Role.parse("""
            name = "r"
            description = "d"
            slots = ["a"]
            ---
            uses {a} and {b}
            """)
        }
    }

    // MARK: composition — slots are hard edges

    @Test("composing with every declared slot fills the template and is inspectable")
    func composesWithAllSlots() throws {
        let role = try Role.parse(planImplementer)
        let task = try role.compose(["plan": "ship X", "constraints": "no network"])
        #expect(task == "You are implementing this plan:\nship X\n\nConstraints: no network")
    }

    @Test("a missing slot is refused — the caller must fill every hard edge")
    func missingSlotFails() throws {
        let role = try Role.parse(planImplementer)
        #expect(throws: Role.ComposeError.self) {
            try role.compose(["plan": "ship X"])   // constraints omitted
        }
    }

    @Test("an unknown slot is refused — no free-text mush past the declared edges")
    func unknownSlotFails() throws {
        let role = try Role.parse(planImplementer)
        #expect(throws: Role.ComposeError.self) {
            try role.compose(["plan": "x", "constraints": "y", "extra": "z"])
        }
    }

    @Test("a slot value containing brace-like text is not re-expanded")
    func slotValueIsNotReinterpreted() throws {
        let role = try Role.parse(planImplementer)
        let task = try role.compose(["plan": "use {constraints} literally", "constraints": "c"])
        // The {constraints} inside the plan value must survive verbatim, not be filled.
        #expect(task.contains("use {constraints} literally"))
    }

    // MARK: library — roles are read from files, unreadable ones are surfaced

    @Test("a library loads every .role file and reports the unreadable, never dropping silently")
    func libraryLoadsAndSurfaces() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-roles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try planImplementer.write(to: dir.appendingPathComponent("plan_implementer.role"),
                                  atomically: true, encoding: .utf8)
        try "not a valid role".write(to: dir.appendingPathComponent("broken.role"),
                                     atomically: true, encoding: .utf8)
        // A non-.role file is ignored entirely.
        try "ignored".write(to: dir.appendingPathComponent("notes.txt"),
                            atomically: true, encoding: .utf8)

        let loaded = RoleLibrary.load(from: dir)
        #expect(loaded.roles.map(\.name) == ["plan_implementer"])
        #expect(loaded.unreadable.map(\.file) == ["broken.role"],
                "an unreadable role is surfaced by name, not silently dropped")
    }

    @Test("a missing roles directory is empty, not an error")
    func missingDirectoryIsEmpty() {
        let loaded = RoleLibrary.load(from: URL(fileURLWithPath: "/no/such/roles/dir/here"))
        #expect(loaded.roles.isEmpty)
        #expect(loaded.unreadable.isEmpty)
    }

    // MARK: layering — shipped ∪ global ∪ project, most-specific wins (override is a feature)

    /// Write one role file with the given `name` into a fresh layer directory.
    private func layer(_ names: [String], into dir: URL, marker: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in names {
            let text = """
            name = "\(name)"
            description = "\(marker) \(name)"
            slots = ["task"]
            ---
            \(marker): {task}
            """
            try text.write(to: dir.appendingPathComponent("\(name).role"),
                           atomically: true, encoding: .utf8)
        }
    }

    private func tempLayers() -> (shipped: URL, global: URL, project: URL, root: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-layers-\(UUID().uuidString)")
        return (root.appendingPathComponent("shipped"),
                root.appendingPathComponent("global"),
                root.appendingPathComponent("project"),
                root)
    }

    @Test("distinct names from every layer union, each carrying its origin")
    func layersUnion() throws {
        let (shipped, global, project, root) = tempLayers()
        defer { try? FileManager.default.removeItem(at: root) }
        try layer(["reviewer"], into: shipped, marker: "S")
        try layer(["planner"], into: global, marker: "G")
        try layer(["domain_expert"], into: project, marker: "P")

        let resolved = RoleLibrary.resolve(shipped: shipped, global: global, project: project)
        let byName = Dictionary(uniqueKeysWithValues: resolved.roles.map { ($0.role.name, $0) })
        #expect(resolved.roles.count == 3)
        #expect(byName["reviewer"]?.origin == .shipped)
        #expect(byName["planner"]?.origin == .global)
        #expect(byName["domain_expert"]?.origin == .project)
        #expect(resolved.roles.allSatisfy { $0.overrides.isEmpty }, "nothing shadowed here")
    }

    @Test("a flat install: global dir == shipped dir loads once, as shipped, no shadow noise")
    func flatInstallUnifiesShippedAndGlobal() throws {
        // The flat ~/.cowork layout puts the shipped roles AT the global layer's
        // path. The same directory must not be read twice — that would list every
        // shipped role as \"global shadowing shipped\", which is bookkeeping noise
        // for an override that never happened.
        let (shipped, _, project, _) = tempLayers()
        try layer(["reviewer", "planner"], into: shipped, marker: "S")
        try layer(["domain_expert"], into: project, marker: "P")

        let resolved = RoleLibrary.resolve(shipped: shipped, global: shipped, project: project)
        let byName = Dictionary(uniqueKeysWithValues: resolved.roles.map { ($0.role.name, $0) })
        #expect(resolved.roles.count == 3)
        #expect(byName["reviewer"]?.origin == .shipped)
        #expect(byName["planner"]?.origin == .shipped)
        #expect(resolved.roles.allSatisfy { $0.overrides.isEmpty },
                "one directory read as two layers must not report self-shadowing")
    }

    /// The feature the user asked for: a project role with a shipped role's NAME
    /// replaces it — callers keep one stable tool name and automatically get the
    /// project's customisation — and the shadowing is RECORDED, never silent.
    @Test("most-specific wins: project overrides global overrides shipped, and says so")
    func mostSpecificWins() throws {
        let (shipped, global, project, root) = tempLayers()
        defer { try? FileManager.default.removeItem(at: root) }
        try layer(["reviewer"], into: shipped, marker: "S")
        try layer(["reviewer"], into: global, marker: "G")
        try layer(["reviewer"], into: project, marker: "P")

        let resolved = RoleLibrary.resolve(shipped: shipped, global: global, project: project)
        #expect(resolved.roles.count == 1, "one name is one tool, whatever the layers hold")
        let winner = try #require(resolved.roles.first)
        #expect(winner.origin == .project)
        #expect(winner.role.template.hasPrefix("P:"), "the project's TEMPLATE is the one served")
        #expect(winner.overrides == [.shipped, .global],
                "every shadowed layer is recorded, most general first — visible, never silent")
    }

    @Test("a global role overrides a shipped one when no project role exists")
    func globalOverridesShipped() throws {
        let (shipped, global, project, root) = tempLayers()
        defer { try? FileManager.default.removeItem(at: root) }
        try layer(["reviewer"], into: shipped, marker: "S")
        try layer(["reviewer"], into: global, marker: "G")

        let resolved = RoleLibrary.resolve(shipped: shipped, global: global, project: project)
        let winner = try #require(resolved.roles.first)
        #expect(winner.origin == .global)
        #expect(winner.overrides == [.shipped])
    }

    @Test("an absent layer is simply skipped")
    func absentLayersSkipped() throws {
        let (_, global, _, root) = tempLayers()
        defer { try? FileManager.default.removeItem(at: root) }
        try layer(["planner"], into: global, marker: "G")

        let resolved = RoleLibrary.resolve(shipped: nil, global: global, project: nil)
        #expect(resolved.roles.map(\.role.name) == ["planner"])
        #expect(resolved.roles.first?.origin == .global)
    }

    @Test("an unreadable role reports WHICH layer it came from")
    func unreadableCarriesOrigin() throws {
        let (shipped, global, project, root) = tempLayers()
        defer { try? FileManager.default.removeItem(at: root) }
        try layer(["reviewer"], into: shipped, marker: "S")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "not a role".write(to: project.appendingPathComponent("broken.role"),
                               atomically: true, encoding: .utf8)

        let resolved = RoleLibrary.resolve(shipped: shipped, global: global, project: project)
        #expect(resolved.roles.count == 1)
        #expect(resolved.unreadable.count == 1)
        #expect(resolved.unreadable.first?.origin == .project)
        #expect(resolved.unreadable.first?.file == "broken.role")
    }
}
