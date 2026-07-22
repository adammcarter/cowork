# Audit Output Format

Every cowork AUDIT-mode report MUST follow this exact structure. Deviation is a malformation — the parent agent will reject the output and re-dispatch.

## Required structure

```markdown
# Audit Report — <topic>

## Verdict
{PASS | PASS-WITH-NOTES | BLOCK | NEEDS-MORE-CONTEXT}

## Confidence
- **Verified hands-on:** <list of artifacts you actually inspected — e.g. read the file, ran the script, checked the sha, traced the code path>
- **Inferred / assumed:** <list of claims you made without direct verification — based on doc text, naming, or pattern-matching>
- **Could not access:** <list of materials you needed but couldn't reach — files referenced but missing, dirs out of sandbox, etc.>

## Findings

### {BLOCKER | CONCERN | NIT} 1 — <short title>
- **Location:** <file:line | commit | byte range | section reference>
- **Evidence:** <what you actually saw — quoted or summarised, not interpreted>
- **Why it matters:** <consequence if unaddressed>
- **Suggested action:** <pointer, not a patch>

### {BLOCKER | CONCERN | NIT} 2 — <title>
...

(If no findings of a given severity, omit that subsection. If NO findings at all, write a single line under `## Findings`: `No findings.`)

## Out-of-scope observations
<bullets — flagged only, not audited. May be empty (write "None.").>

## Sign-off
<one-line summary — verdict + most important finding if not PASS>
```

## Severity definitions

- **BLOCKER** — would cause the audited approach to fail, produce wrong results, or violate a load-bearing invariant. Stop and address before proceeding. A BLOCKER must reference verified-hands-on evidence; if the strongest evidence is inferred, downgrade.
- **CONCERN** — a real risk or gap. Should be addressed but not necessarily a stop-the-world. May reference inferred evidence as long as that's stated.
- **NIT** — minor, cosmetic, or judgement-call. Optional to address. Use sparingly: if you find yourself writing more than 3 NITs, reconsider whether they're really findings or just preferences.

## Verdict definitions

- **PASS** — no findings, the audited approach is sound. The auditor verified the load-bearing claims hands-on.
- **PASS-WITH-NOTES** — only NITs and/or CONCERNs (no BLOCKERs). The approach proceeds with minor adjustments. The Sign-off line names the most important note.
- **BLOCK** — at least one BLOCKER. The audited approach must NOT proceed without addressing the blocker(s). The Sign-off line names the blocker.
- **NEEDS-MORE-CONTEXT** — the brief was insufficient or inaccessible material prevented audit. List exactly what's missing under `Could not access`. Do not produce findings under this verdict — surface the gap, not partial work.

## Confidence section — why it's load-bearing

The Confidence section is what makes an audit trustworthy. The auditor MUST be honest about:

- **Verified hands-on:** what was confirmed by direct file read, grep, sha-check, command output, or trace. Cite the specific verification.
- **Inferred / assumed:** what was concluded from secondary signals — doc text claiming X, naming conventions suggesting Y, pattern-matching to similar code. Useful but weaker.
- **Could not access:** what was needed but unavailable. Files referenced in the brief but not present. Dirs out of sandbox. Live data not captured. Tools missing.

A finding's strength is bounded by its evidence. Audit consumers (Claude, the user) read the Confidence section to calibrate how much to trust each finding.

If `Could not access` is non-empty, the auditor must consider whether the missing material would change any finding. If yes — verdict is NEEDS-MORE-CONTEXT. If no — proceed with the audit but state the limitation in Sign-off.

## Style rules

- **Specific over general.** "Spec line 47 cites byte offset 0x1234, but the actual byte at 0x1234 is 0x00 not 0xFF as claimed" beats "the spec has factual errors."
- **Quote, don't paraphrase, evidence.** When the evidence is a piece of text, quote it verbatim. When it's a piece of code or bytes, copy it verbatim. Paraphrasing introduces auditor-bias.
- **One finding per issue.** Don't combine "X is wrong AND Y is wrong" into a single finding even if they're related — separate findings keep severity ratings honest.
- **No nested findings.** Findings are a flat list under `## Findings`. Don't nest sub-findings under a parent finding. If a finding has multiple aspects, split it.
- **No "if I were doing this..."** Audits report observations against criteria, not author preferences. If you'd do something differently, ask whether the criteria say it's wrong. If yes, finding. If no, don't write it.

## Example — clean PASS

```markdown
# Audit Report — refactor-of-cache-key-builder

## Verdict
PASS

## Confidence
- **Verified hands-on:** read all 4 files in scope (`src/cache/key.rs`, `src/cache/key_test.rs`, `Cargo.toml`, `docs/cache-format.md`); ran `cargo test cache::key`; diffed against `main`.
- **Inferred / assumed:** that the upstream callers in `src/api/` are unchanged (out of scope per brief).
- **Could not access:** none.

## Findings
No findings.

## Out-of-scope observations
None.

## Sign-off
PASS — the refactor preserves behaviour, tests pass, and the new keying scheme matches `docs/cache-format.md` §3.2.
```

## Example — BLOCK with one finding

```markdown
# Audit Report — record-envelope-versioning

## Verdict
BLOCK

## Confidence
- **Verified hands-on:** read `Sources/CoworkCore/Records.swift`; confirmed the record envelope carries a schema version, and that a load encountering an unknown version is reported as `.unreadable` rather than silently coerced.
- **Inferred / assumed:** that every caller treats `.unreadable` as terminal (the result case exists, but not all call sites were observed handling it).
- **Could not access:** none.

## Findings

### BLOCKER 1 — Corrupt-record load drops the decode diagnostic
- **Location:** the load path in `Records.swift` that produces `.unreadable`.
- **Evidence:** a truncated record and an unknown-version record both surface as `.unreadable` with no reason attached, so a caller cannot tell a torn write from a schema mismatch.
- **Why it matters:** losing the decode reason makes field corruption hard to triage and easy to mistake for a benign miss.
- **Suggested action:** attach the underlying decode error to the `.unreadable` result so callers can log it and distinguish causes.

## Out-of-scope observations
None.

## Sign-off
BLOCK — the corrupt-record path must preserve the decode diagnostic before this can ship.
```
