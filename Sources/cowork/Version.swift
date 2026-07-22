/// The single source of truth for cowork's released version.
///
/// One string, in one place, so a release cannot half-happen. The MCP server
/// reports this in `initialize`; the release pipeline (`scripts/check-release-ready.sh`)
/// refuses to build a tag whose `vX.Y.Z` does not equal this exact value. A
/// release is therefore always a deliberate bump commit that lands *before* the
/// tag — never a tag racing ahead of the binary it names.
let coworkVersion = "0.0.1"
