import Foundation
import Testing

@testable import CoworkCore

/// ADR 000: a credential never reaches a child's argv or environment, a log, a
/// record, an event, a diagnostic, or a transcript.
///
/// That was audited by hand after a live NVIDIA run — grep the artifacts, find
/// nothing, feel good. A manual audit proves one moment and rots immediately: the
/// next `print` or `Codable` conformance silently undoes it. These pin the
/// property to the type, where it cannot rot quietly.
@Suite("Credential redaction")
struct CredentialTests {
    private let secret = "sk-live-DO-NOT-LEAK-4f9a2b7c"

    @Test("string interpolation cannot leak a credential")
    func interpolationIsRedacted() {
        let credential = Credential(secret)
        // The most likely accident in the codebase: someone interpolates a
        // credential into a diagnostic while debugging and ships it.
        let interpolated = "auth=\(credential)"
        #expect(!interpolated.contains(secret))
        #expect(interpolated.contains("redacted"))
    }

    @Test("description and debugDescription are both redacted")
    func bothDescriptionsRedacted() {
        let credential = Credential(secret)
        #expect(!credential.description.contains(secret))
        #expect(!credential.debugDescription.contains(secret))
        // po in a debugger, dump(), and %@ all route through one of these two.
        #expect(!String(describing: credential).contains(secret))
        #expect(!String(reflecting: credential).contains(secret))
    }

    @Test("dump — which walks stored properties — does not reveal the value")
    func dumpIsRedacted() {
        let credential = Credential(secret)
        var output = ""
        // dump() reflects over stored properties rather than calling description,
        // so a type that only overrode description would leak here.
        dump(credential, to: &output)
        #expect(!output.contains(secret))
    }

    /// The one deliberate escape hatch. It is ugly on purpose: any other use reads
    /// as a mistake in review.
    @Test("the value is reachable only through the one named accessor")
    func exposeIsTheOnlyWayOut() {
        let credential = Credential(secret)
        #expect(credential.exposeForAuthorizationHeader() == secret)
    }

    @Test("a credential in a collection is still redacted")
    func redactedInsideContainers() {
        let credentials = ["nvidia": Credential(secret)]
        #expect(!"\(credentials)".contains(secret))
        #expect(!String(describing: [Credential(secret)]).contains(secret))
    }

    // MARK: loading

    @Test("an absent variable yields no credential, rather than an empty one")
    func absentIsNil() {
        #expect(Secrets.load("COWORK_DEFINITELY_NOT_SET_\(UUID().uuidString)") == nil)
    }

    /// An empty value is the shape of a half-finished .env: `NVIDIA_API_KEY=` with
    /// nothing after it. Treating that as a credential would send `Bearer ` and
    /// produce a 401 the user cannot explain. Absent is the honest reading.
    @Test("an empty value is absent, not a credential")
    func emptyIsAbsent() {
        let name = "COWORK_TEST_EMPTY_\(UUID().uuidString.prefix(8))"
        setenv(name, "", 1)
        defer { unsetenv(name) }
        #expect(Secrets.load(name) == nil)
    }

    @Test("the environment is read when the variable is set")
    func loadsFromEnvironment() {
        let name = "COWORK_TEST_KEY_\(UUID().uuidString.prefix(8))"
        setenv(name, secret, 1)
        defer { unsetenv(name) }
        let loaded = Secrets.load(name)
        #expect(loaded?.exposeForAuthorizationHeader() == secret)
        #expect(!"\(loaded!)".contains(secret), "even freshly loaded, it stays redacted")
    }
}
