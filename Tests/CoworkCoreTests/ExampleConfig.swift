import Foundation
import Testing

@testable import CoworkCore

/// The shipped `examples/config.toml`, loaded once, as the subject of the wire tests.
///
/// Those wires used to be Swift constants (`BuiltinDescriptors`), which is exactly
/// what the generalisation removed: cowork ships no agents, so the only place a wire
/// can live is a config file. Pointing the frozen pins at the shipped example keeps
/// them doing their original job — catching drift in argv/stdin/parse behaviour — and
/// adds one they could not do before: proving the file users are told to copy is the
/// file the parser actually accepts.
enum ExampleConfig {
    /// Repo-relative, from this source file: the tests run from an unpredictable cwd,
    /// but the checkout's own layout is fixed.
    static let url: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // Tests/CoworkCoreTests
        .deletingLastPathComponent()      // Tests
        .deletingLastPathComponent()      // repo root
        .appendingPathComponent("examples/config.toml")

    static let config: Config = {
        // A failure here is the point of the fixture, so let it be loud.
        try! Config.load(global: url, project: nil)
    }()

    static func descriptor(_ name: String) throws -> CliDescriptor {
        try #require(config.cli[name]?.descriptor)
    }

    static func driver(_ name: String) throws -> ConfiguredDriver {
        let cli = try #require(config.cli[name])
        return ConfiguredDriver(name: cli.name, executable: cli.executable,
                                descriptor: cli.descriptor)
    }

    static func agent(_ name: String) throws -> ConfiguredAgent {
        ConfiguredAgent(try #require(config.cli[name]))
    }
}
