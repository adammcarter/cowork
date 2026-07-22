import Foundation
import Testing

@testable import CoworkCore

/// The one Outcome value every CLI one-shot produces, shared rather than
/// re-declared per backend. Two field-identical structs were exactly the
/// duplication the fork abstraction removes.
@Suite("CliOutcome")
struct CliOutcomeTests {
    @Test("carries the worker's declaration, with an empty transcript and no continuation by default")
    func defaults() {
        let o = CliOutcome(state: .succeeded, text: "hi", diagnostics: ["d"])
        #expect(o.state == .succeeded)
        #expect(o.text == "hi")
        #expect(o.diagnostics == ["d"])
        #expect(o.transcript == "")
        #expect(o.continuation == nil)
    }

    @Test("holds a transcript and a continuation handle when the worker declares one")
    func fullyPopulated() {
        let o = CliOutcome(state: .failed, text: "", diagnostics: ["cli.no-declared-result"],
                           transcript: "said: hello\n", continuation: "sess-1")
        #expect(o.transcript == "said: hello\n")
        #expect(o.continuation == "sess-1")
    }
}
