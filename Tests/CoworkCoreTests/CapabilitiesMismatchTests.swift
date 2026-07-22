import Foundation
import Testing

@testable import CoworkCore

/// The kind/executable cross-check (open question 1's recommended answer): identity
/// is the executable's, and a config `kind` that disagrees is neither obeyed
/// silently nor a reason to refuse a working binary — it is reported as a fact.
@Suite("Capabilities kind/executable cross-check")
struct CapabilitiesMismatchTests {
    struct NoProbe: EndpointProbe {
        func get(url: URL, headers: [String: String]) async throws -> ProbeResponse {
            ProbeResponse(status: 200, body: Data())
        }
    }

    private func installedExecutable(named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cowork-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func config(_ cli: CliConfig) -> Config {
        Config(providers: [:], cli: [cli.name: cli], visible: [:])
    }

    @Test("a config kind that disagrees with the executable is reported, and identity still follows the executable")
    func mismatchReported() async throws {
        // Labelled claude, but the binary is grok.
        let grokBinary = try installedExecutable(named: "grok")
        let cli = CliConfig(name: "mine", executable: grokBinary, kind: .claude, origin: .global)

        let facts = try await Capabilities.facts(backend: "mine", config: config(cli),
                                                 probe: NoProbe(), secrets: { _ in nil })

        #expect(facts[0].diagnostics.contains("cli.kind-mismatch"))
        #expect(facts[0].diagnostics.contains("configured=claude"))
        // Identity follows the executable, not the mislabel: the binary is classified
        // as grok — `executable=grok` is the proof — and gets grok's own capabilities
        // (grok is SessionCapable too, so message support is not the distinguisher; the
        // recorded mismatch is). It is not silently run as the claude it was labelled.
        #expect(facts[0].diagnostics.contains("executable=grok"), "classified as grok, not claude")
        #expect(facts[0].supportsMessage == true, "grok's own ACP session — from the executable's identity")
    }

    @Test("a matching kind reports no mismatch")
    func matchNoDiagnostic() async throws {
        let claudeBinary = try installedExecutable(named: "claude")
        let cli = CliConfig(name: "c", executable: claudeBinary, kind: .claude, origin: .global)

        let facts = try await Capabilities.facts(backend: "c", config: config(cli),
                                                 probe: NoProbe(), secrets: { _ in nil })

        #expect(facts[0].diagnostics.contains("cli.kind-mismatch") == false)
        #expect(facts[0].supportsMessage == true)
    }
}
