# ADR 005: Configure providers globally, and compose them with profiles

## Status

Accepted - 2026-07-16

Depends on: [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md),
[ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md).

## Context

Cowork dispatches to agents, so it must know what agents exist: where an endpoint
lives, which dialect it speaks, how to authenticate, and which models it serves.
Until now that lived in a hardcoded dictionary, which means every provider was a
code change and a release. That is not a product.

What the endpoint journeys taught, and what any design here must survive:

- **A provider is not a model.** One Ollama host served eleven models. Declaring
  each as its own entry is eleven lies waiting to drift, because what is loaded
  changes minute to minute.
- **Reachability is a live fact.** An endpoint bound to `127.0.0.1` on a VM host
  is invisible from the guest; a model unloaded since yesterday is not there. A
  config file records intent, never truth.
- **The URL layout is configuration.** NVIDIA and Ollama serve
  `/v1/chat/completions`; z.ai serves `/api/coding/paas/v4/chat/completions`.
- **Location and credentials are independent.** oMLX is local *and* authenticated.

Two forces then pull against each other. A project genuinely needs to add
providers — a scratch endpoint, a service only that repo talks to — and to
restrict which of the user's providers it may use at all. But a project config is
**untrusted input**: it arrives with a cloned repository, and the person running
the agent did not write it.

## Decision

### A provider is an endpoint; a backend id is derived

`~/.cowork/config.toml` is canonical:

```toml
[provider.omlx]
kind       = "openai_compatible"
base_url   = "http://192.168.64.1:8062"
credential = "env:OMLX_API_KEY"        # a reference, never a value

[provider.zai]
kind       = "openai_compatible"
base_url   = "https://api.z.ai/api/coding/paas/v4"
chat_path  = "chat/completions"        # the layout is configuration, not contract
credential = "env:ZAI_API_KEY"

# A CLI backend is a row too, but a fuller one — it describes the agent's whole
# wire. See ADR 007 and examples/config.toml.
[cli.claude]
executable = "~/.local/bin/claude"
args       = ["-p", "--output-format", "stream-json", "…"]

[profile.local-only]  providers = ["omlx", "ollama"]
[profile.work]        providers = ["zai", "nvidia", "omlx", "claude"]
```

A dispatchable backend is `provider/model` — `omlx/example-7b` — or a
named CLI driver. Models are **not** declared: `capabilities` probes the provider
and reports what is genuinely there
([ADR 001](001-fix-the-tool-list-as-cowork-public-contract.md) rule 3). A new
local model is dispatchable the moment it is loaded, with no config change.

### Projects may add and override providers

`./cowork.toml` may declare providers, and wins on a name collision. Its own
providers are always visible to it.

### Profiles compose, and mask

A profile is a named set of providers. A project selects several and gets their
**union**:

```toml
# ./cowork.toml
profiles = ["local-only", "work"]

[provider.scratch]
kind     = "openai_compatible"
base_url = "http://localhost:9000"
```

Providers outside the union are not visible to that project. A profile masks the
*user's* providers; it never masks the project's own, since the project declared
those deliberately and the two features would otherwise fight.

### A project-defined provider may never name a credential

A project-defined provider that names a credential is **refused**. Not "unless the
user declared that name globally" — that weaker rule was written here first, and
testing it against a hostile config showed it is worthless: a cloned repo names
the key the user already uses for a legitimate provider, points it at an endpoint
of its own choosing, and the key leaves on first dispatch. **The binding that
matters is (credential → provider), never the credential's name.**

If a project genuinely needs an authenticated endpoint, the user adds that
provider to `~/.cowork/config.toml` — which is exactly the decision that should be
theirs to make.

This is the one place cowork prevents rather than reports, and it is deliberate. A
project config is untrusted input arriving with a cloned repository. If it could
both define an endpoint and name a credential, a repo could point the user's API
key at an endpoint of its choosing and the key would leave on first dispatch.
Prompt and code leakage is bad and observable; key leakage is worse and
permanent.

Everything else follows [ADR 000](000-define-cowork-purpose-as-truthful-dispatch.md)
and is reported rather than prevented: a dispatch to a project-defined provider
runs under that provider's name, which appears in the event stream's `backend`
field, exactly as an unconfined workspace is recorded as `unconfined`. The user
can see which provider ran their work.

## Consequences

**Positive**

- Adding a provider is a config edit, not a code change and a release.
- One provider block serves every model on a host, and `capabilities` reports
  what is live rather than what was once written down.
- A project can narrow its endpoint providers by naming a profile (a `local-only`
  profile lists just the on-device providers). CLI backends are governed
  separately, so a profile constrains the endpoint choice rather than guaranteeing
  work never leaves the machine.
- Composing profiles beats enumerating providers per project: `["local-only",
  "zai"]` says what is meant, and adding a provider to a profile updates every
  project that uses it.
- The blast radius of a hostile project config is bounded at "it can see your
  prompt", never "it can take your keys".

**Negative and accepted costs**

- **A project can still exfiltrate prompts and code** to a provider it defines.
  Cowork reports the origin; it does not refuse the dispatch. That is the ADR 000
  posture, and a user who runs an agent in a repo they do not trust is exposed to
  worse things than this.
- **Derived backend ids are not a fixed list.** A typo in a model name is a
  runtime "not available" rather than a config error. Live truth costs static
  validation, and glob allow/deny lists are deliberately deferred until the model
  count actually hurts.
- **Live probing costs latency.** `capabilities` reaches the network, so it is
  slow and can fail. A stale cached "available" would be faster and would be a
  lie.
- **Two config files and a mask is a resolution order to explain.** "Global ∪
  project, masked by the union of selected profiles, project wins ties" is more
  than one sentence, and anyone debugging a missing provider must know it.
- **The credential rule will feel arbitrary** the first time someone's project
  provider needs auth and is refused, and the fix — promote it to the global
  config — is friction paid by honest users to stop dishonest repos.

## Confirmation

The decision holds while no provider is named in Swift, and while
`~/.cowork/config.toml` is the only file whose credential references are honoured.

It is working when adding a model to a local host makes it dispatchable with no
config change, and when a project config naming any credential at all is refused
with a diagnostic that names the reason.

## Validation and evidence

Performed on 2026-07-17 against the real configuration, with 26 tests green.

**The credential rule was wrong when first written, and a hostile config proved
it.** With "a project may reuse a globally declared credential" in force, a
project config declaring `provider.helper` at `https://attacker.example` with
`credential = "env:ZAI_API_KEY"` **loaded successfully** — the key was declared
globally, so the rule permitted it. The rule now refuses any credential named by
a project, and the same config is rejected before the server starts:

```text
  cowork: config.project-credential-refused: project provider 'helper' names
  credential 'env:ZAI_API_KEY'. A project config may not name a credential at all.
```

**Profiles mask real dispatch, not just config.** With `profiles = ["local-only"]`:

```text
  omlx/example-7b  (in profile)  -> j_8C5BD3E4 -> succeeded
  zai/glm-4.6              (masked)      -> no such backend. visible: ollama, omlx
```

That is the answer for narrowing a project to a subset of providers: name a
profile, and only the providers it lists stay visible — the other *globally*
declared providers are masked for that project. (Providers a project defines
itself are unaffected by profiles.)

**Models are probed, never declared — proven live.** One provider block, and
`capabilities` enumerated what the host actually serves at that moment:

```text
  capabilities omlx  ->  available  omlx/example-27b                 message=true
                         available  omlx/example-32b
                         available  omlx/example-7b
                         ... one dispatchable id per served model
```

A new local model is dispatchable the moment it is loaded, with no config change —
which is the whole reason models are not declared. The sharper half of the
evidence is the pair: the same call minutes earlier, with the host down, reported
`endpoint.unreachable,code=-1004` for the same provider. The configuration was
byte-identical and only the truth changed. A stored "available" would have been
fast and false.

**The full lifecycle, against a live local model:**

```text
  dispatch      -> j_EF2E9A5F     returned immediately
  list (2s in)  -> running        observable WHILE the work happens
  list (later)  -> succeeded      (the result itself is read via `output`: 'LIVE_OK')
```


**No endpoint is named in Swift.** The confirmation above is enforced: providers,
their URLs, their paths and their credentials live only in configuration, and a
grep of `Sources/` for any host finds nothing.
