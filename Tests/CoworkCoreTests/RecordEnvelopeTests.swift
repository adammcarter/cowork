import Foundation
import Testing

@testable import CoworkCore

@Suite("Record envelope", .serialized)
struct RecordEnvelopeTests {
    private func withHome(_ body: () throws -> Void) throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-record-envelope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try Store.$rootOverride.withValue(home) {
            try Store.prepare()
            try body()
        }
    }

    private func record(id: String) -> DispatchRecord {
        DispatchRecord(id: id, parent: "s_parent", root: "s_root", backend: "fixture",
                       task: "work", workspace: nil, state: .running,
                       diagnostics: [], result: nil)
    }

    @Test("saved records carry schema version 1 and round-trip")
    func savedRecordIsVersioned() throws {
        try withHome {
            let expected = record(id: "j_current")
            try expected.save()

            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: expected.file))
                                      as? [String: Any])
            #expect(object["schemaVersion"] as? Int == 1)
            guard case let .loaded(actual) = DispatchRecord.loadResult(expected.id) else {
                Issue.record("saved record did not load")
                return
            }
            #expect(actual.id == expected.id)
            #expect(actual.state == expected.state)
        }
    }

    @Test("version-less legacy records load as schema version 1")
    func legacyRecordLoads() throws {
        try withHome {
            let legacy = """
                {"id":"j_legacy","parent":"s_parent","root":"s_root","backend":"fixture",\
                "task":"work","state":"running","diagnostics":[]}
                """
            try Store.writeAtomically(Data(legacy.utf8),
                                      to: Store.dispatchDir("j_legacy").appendingPathComponent("job.json"))

            guard case let .loaded(actual) = DispatchRecord.loadResult("j_legacy") else {
                Issue.record("version-less record did not load")
                return
            }
            #expect(actual.id == "j_legacy")
        }
    }

    @Test("a newer schema version fails with a named diagnostic")
    func newerSchemaVersionIsNamed() throws {
        try withHome {
            let newer = """
                {"schemaVersion":2,"id":"j_future","parent":"s_parent","root":"s_root",\
                "backend":"fixture","task":"work","state":"running","diagnostics":[]}
                """
            try Store.writeAtomically(Data(newer.utf8),
                                      to: Store.dispatchDir("j_future").appendingPathComponent("job.json"))

            guard case let .unreadable(diagnostic) = DispatchRecord.loadResult("j_future") else {
                Issue.record("newer record was not rejected")
                return
            }
            #expect(diagnostic.contains("record.unsupported-schema-version"))
            #expect(diagnostic.contains("version=2"))
        }
    }

    @Test("a corrupt record is unreadable rather than missing")
    func corruptRecordIsNotMissing() throws {
        try withHome {
            try Store.writeAtomically(Data("{not json".utf8),
                                      to: Store.dispatchDir("j_corrupt").appendingPathComponent("job.json"))

            guard case let .unreadable(diagnostic) = DispatchRecord.loadResult("j_corrupt") else {
                Issue.record("corrupt record was reported as missing")
                return
            }
            #expect(diagnostic.contains("record.unreadable"))
            guard case .missing = DispatchRecord.loadResult("j_absent") else {
                Issue.record("absent record was not reported as missing")
                return
            }
        }
    }
}
