# Specialist selection — pick-when, anti-triggers, and classes

The judgment half of the old specialist catalog. The POV and stay-in-lane of each
specialist live in its role file (the `role_review_*` tool IS the specialist);
this table is what the ORCHESTRATING AGENT uses to decide WHICH to dispatch and
WHEN to re-dispatch. Pick all-that-apply, generously: over-pick is cheaper than
under-pick because specialists run in parallel.

Classes control the iteration loop:
- **gatekeeper** — re-dispatch when fold-in changed code in their domain, or when
  later edits entered their domain even if they were silent earlier.
- **advisory** — one-shot; findings are valuable without patches; never pressure
  them to manufacture patchable issues.
- **closure** — `role_review_senior`, always on: round 1 AND again at final
  closure after the loop stops.

## `role_review_security` — Security & abuse paths

**Class:** gatekeeper.

**Pick when:** diff touches input parsers, file paths, shell/process execution, external APIs, network code, deserialization, secrets/credentials, auth logic, crypto, dependency additions, anything reachable from user/untrusted data.

**Do not pick merely because:** a file contains the word "token", "auth", or "key" where these are parser tokens / config field names / cryptographic material with no trust boundary.


## `role_review_architecture` — Architecture & boundaries

**Class:** gatekeeper.

**Pick when:** diff touches module boundaries, public/internal access modifiers, dependency declarations (`Package.swift`, import graphs), cross-cutting helpers, new abstractions, anything that changes where code-X lives relative to code-Y.

**Also pick when:** any file exists in `.cowork/review/` in the repo root — `architecture.md` (structural patterns), `project.md` (role & responsibility boundaries), or any future sibling. Auto-include review_architecture and absorb all present files into the shared brief. Each file describes a different lens on what the project must and must not do; review_architecture checks the diff against all of them.

**Do not pick merely because:** a single function got long or a name is poor (that's review_clarity).

**Easily confused:** review_architecture flags structural problems *now*; review_latent_risk flags structural risks that will bite *later* if something else changes.


## `role_review_performance` — Performance, scalability & resource use

**Class:** gatekeeper.

**Pick when:** diff touches loops over potentially-large collections, I/O patterns, allocation-heavy code, caching, parallelism, anything in a path that runs per-frame / per-asset / per-request, or anything that handles "the cohort" (HRH + non-HRH) where data scales.

**Do not pick merely because:** the code is "complex" (that's review_clarity) or uses an unusual language feature (that's review_idioms).


## `role_review_api` — API & interface design

**Class:** gatekeeper.

**Pick when:** diff touches public/exposed types, function signatures, protocol/interface declarations, CLI flags, configuration schemas, serialized formats consumed by other code, anything with downstream consumers (internal or external).

**Do not pick merely because:** an internal function's name is poor (that's review_clarity) or internal restructuring happened (that's review_architecture).


## `role_review_resilience` — Resilience & failure semantics

**Class:** gatekeeper.

**Pick when:** diff touches I/O that can fail, network calls, subprocess invocations, file handles / cleanup, error paths, retry logic, cancellation, async work that can be torn down mid-flight.

**Do not pick merely because:** an assertion is missing in tests (that's review_test_oracle) or a thread is involved (that's review_concurrency).

**Easily confused:** review_resilience = "what happens when the network drops / file is missing?"; review_concurrency = "what happens when two tasks race to the same state?". Pick both when async code also does I/O.


## `role_review_test_oracle` — Test oracle & behavior coverage

**Class:** gatekeeper.

**Pick when:** diff changes behaviour (any non-trivial code edit), adds/ modifies test files, adds/removes oracles or expected values, changes how results are validated.

**Do not pick merely because:** there are many tests (count isn't quality) or the test infrastructure looks complex (that's review_test_harness).

**Easily confused:** review_test_oracle = "does this test prove the right thing?"; review_test_harness = "is the test harness itself trustworthy?". Pick both when test infrastructure and new test logic change together.


## `role_review_clarity` — Local code clarity & maintainability

**Class:** gatekeeper.

**Pick when:** diff touches non-trivial logic, introduces new abstractions, or changes file/function structure.

**Do not pick merely because:** a function exceeds N lines (line count isn't clarity) — only flag when the structure genuinely impedes understanding.


## `role_review_latent_risk` — Latent risk & hidden invariants

**Class:** **advisory.** One-shot by default. Findings are valuable even when no patch results — don't pressure review_latent_risk to manufacture patchable issues. Re-dispatch only if remediation in another reviewer's domain materially changed architecture or assumptions.

**Pick when:** diff introduces non-obvious dependencies between modules, relies on implicit ordering / timing / state, adds branches whose conditions are subtle, or modifies code where a future change in one place would silently break another.

**Do not pick merely because:** the code has "tech debt" or could be "cleaner" (those are review_clarity).

**Easily confused:** review_latent_risk flags what is *silently relied on* but not structurally enforced; review_architecture flags what is *structurally wrong right now*.


## `role_review_concurrency` — Concurrency & state safety

**Class:** gatekeeper.

**Pick when:** diff touches `async`/`await`, `Task`, actors, `@Sendable`, callbacks, NotificationCenter, shared caches/singletons, mutable global/ static state, test parallelism, UI/main-thread handoff, file/process watchers, background jobs.

**Do not pick merely because:** the code uses `Task { ... }` for a fire- and-forget log call with no shared state (cost without payoff).

**Easily confused:** see review_resilience entry. Pick both when async I/O code can fail AND race.


## `role_review_debuggability` — Observability & debuggability

**Class:** gatekeeper.

**Pick when:** diff touches CLIs, long-running jobs, parsers, external tool integrations, capture pipelines, background dispatch, test harnesses, or any code whose failure would otherwise be opaque.

**Do not pick merely because:** code lacks `print` statements (logging verbosity isn't the goal — investigability is).


## `role_review_data_model` — Data model, schema & migration risk

**Class:** gatekeeper.

**Pick when:** diff touches database schemas, JSON/plist/protobuf formats, binary fixture formats, snapshot literal shapes, asset catalogs, migration scripts, saved state, or versioned public data.

**Do not pick merely because:** a Swift struct gained a field (that's review_api if public, or local code change otherwise).


## `role_review_build` — Build, packaging & toolchain

**Class:** gatekeeper.

**Pick when:** diff touches `Package.swift`, build scripts, CI configs, generated-code tools, `.xcodeproj`/workspace files, plugin/MCP packaging, shell scripts, lockfiles, binary resources, release docs.

**Do not pick merely because:** a file is configuration-shaped (only flag when the change affects build/CI/release).


## `role_review_idioms` — Language & platform idioms (Swift)

**Class:** gatekeeper.

**Pick when:** diff touches Swift core logic, unsafe APIs (`Unsafe*`, raw pointers, `withMemoryRebound`), platform APIs (Foundation, Darwin), public Swift types, performance-sensitive value types, any language-version upgrade or refactor.

**Do not pick merely because:** Swift is the language (only flag when the diff touches a known footgun area).


## `role_review_test_harness` — Test infrastructure & harness discipline

**Class:** gatekeeper.

**Pick when:** diff touches test utilities, fixtures, snapshot record/update mechanisms, CI test commands, generated baselines, or any change where expected-output update is part of the work.

**Do not pick merely because:** new tests were added (those are reviewed by review_test_oracle).

**Easily confused:** review_test_harness = "is the harness itself trustworthy?"; review_test_oracle = "does this test prove the right thing?".


## `role_review_determinism` — Reproducibility & determinism

**Class:** gatekeeper.

**Pick when:** diff touches sorting, hashing, snapshots, rendering, parallelism, file-system walks, randomised algorithms, generated fixtures, date/time handling, floating-point comparisons, or output that becomes evidence.

**Do not pick merely because:** the code uses a hash function (only flag when the hash output is consumed in a way that requires stability across runs).


## `role_review_ux` — UX, accessibility & i18n

**Class:** gatekeeper.

**Pick when:** diff touches UI, CLI flags/output, command prompts, web/ front-end code, user-visible strings, docs meant for end users, localisation, or accessibility surfaces.

**Do not pick merely because:** the code is in a "front-end" file (only flag when the diff affects user-visible behaviour).


## `role_review_privacy` — Privacy, compliance & licensing

**Class:** gatekeeper.

**Pick when:** diff touches user data, telemetry, logs that could include PII, datasets, dependency additions (licence audit), generated assets, external APIs that receive user data, distribution packaging.

**Do not pick merely because:** the code logs something (only flag when the log content could include sensitive data or violates retention).


## `role_review_documentation` — Documentation & explanatory contract

**Class:** gatekeeper (with advisory mode when findings are purely explanatory rather than correctness-gating — say so in the report).

**Pick when:** diff touches docs, specs, comments around non-obvious code, public APIs, command help, reviewer prompts, `@claim` prose, or changes behaviour without updating accompanying docs.

**Do not pick merely because:** a file has few comments (absence isn't a defect — only flag drift / misleading / missing where the WHY is non-obvious).

**Easily confused:** review_documentation = docs *absent* where needed; review_docs_drift = docs *present but wrong* after this diff.


## `role_review_dead_code` — Dead & orphaned code

**Class:** gatekeeper.

**Pick when:** diff removes call sites (leaving possible orphans), renames/ moves symbols without updating all references, adds a new abstraction alongside an old one without retiring the old one, is a refactor where unused exports or unreachable branches may linger, OR introduces conditional logic whose branches are never reachable given invariants visible in this diff.

**Do not pick merely because:** the diff is large — flag only when there is concrete evidence of dead weight (removed call sites, renamed symbols, parallel implementations coexisting, demonstrably unreachable branches).


## `role_review_docs_drift` — Docs-vs-code drift

**Class:** advisory. Findings without patches are valuable — naming the contradiction IS the deliverable.

**Pick when:** diff changes the behaviour of an already-documented function or module — comment says "returns nil on failure" but code now throws; README says "no external deps" but `Package.swift` adds one; inline docs describe the old algorithm after a rewrite.

**Do not pick merely because:** the code is undocumented — that's review_documentation's territory. review_docs_drift fires only when docs exist and the diff makes them wrong.

**Easily confused:** review_documentation = docs absent; review_docs_drift = docs present but now contradicted by the diff.


## `role_review_observability` — Observability & instrumentation

**Class:** gatekeeper.

**Pick when:** diff touches logging calls, metric emission, trace/span instrumentation, error handling paths (especially catch/recover blocks), health-check endpoints, monitoring configuration, or alerting rules. Also pick when a new code path is added with no corresponding observability.

**Do not pick merely because:** logging exists somewhere in the diff. Pick only when the change could plausibly degrade or remove observability on an important path.

**Easily confused:** review_performance flags runtime cost; review_observability flags whether the runtime is visible at all. A fast path with no metrics is a review_observability finding, not review_performance.


## `role_review_complexity` — Unnecessary complexity & YAGNI

**Class:** advisory. Findings without patches are valuable — naming the unjustified complexity IS the deliverable.

**Pick when:** diff introduces a new abstraction layer, protocol/interface with a single implementation, generic/parameterised type where a concrete type would do, configurable behaviour with one configuration, or "extensible" structure with no current extension points actually used.

**Do not pick merely because:** the code is long, or uses generics, or has indirection — only flag when the added complexity demonstrably exceeds the current problem. If a second use case is already in the diff, the generalisation is earning its place.

**Easily confused:** review_clarity = hard to read; review_complexity = solves the wrong problem (or a problem that doesn't exist yet). Code can be perfectly readable and still be over-engineered.


## `role_review_api_currency` — External API currency

**Class:** advisory.

**Pick when:** diff adds or modifies calls to external libraries, platform SDKs, network protocols, wire formats, or language stdlib features where deprecation is plausible — especially in fast-moving ecosystems (Apple platforms, Node.js, cloud SDKs, ML frameworks). Also pick when a dependency version is pinned to a major-version that has a successor, or when `#available` / version-guard logic is added or changed.

**Do not pick merely because:** a library version is old — flag only when there is a concrete deprecated API in use, a superseded pattern with a documented replacement, or a demonstrably superfluous version guard.


## `role_review_availability` — Platform availability & deployment targets

**Class:** advisory.

**Pick when:** diff adds or modifies calls to platform SDK APIs (Apple, Android, Win32, web APIs, etc.), changes deployment target / minimum version settings, adds new public API that uses platform-versioned features, or touches `Package.swift` / `build.gradle` / `Podfile` minimum-version fields.

**Do not pick merely because:** the diff is large — flag only when there is a concrete mismatch between declared minimum and APIs used, or when availability guards are missing or incorrect.


## `role_review_senior` — Senior staff engineer / PR approver

**Class:** **closure.** Runs as part of round 1 alongside selected specialists, AND again at final synthesis after the loop has otherwise stopped — so the Senior Engineer can re-evaluate PR-approval verdict after fold-ins have landed.

**Pick when:** always. Senior Engineer runs on every `/cowork:review` invocation.

