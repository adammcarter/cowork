# Future work

Deliberately deferred directions. Nothing here is committed; each entry could be
picked up later only behind an explicit decision.

## Credential storage

**What.** The `keychain:` credential-reference scheme has been removed — from the
config parser, its error message, and every code comment. `env:` (a process
environment variable, or a `.env` file beside the current working directory) is
now the single supported secret store.

**Why.** Cowork is a single-user local dispatch tool whose credentials already
live in a readable plaintext `.env`, so a Keychain-backed store was marginal
hardening at real complexity cost. Worse, keeping a half-wired scheme that parsed
as *valid* and then silently failed at dispatch was untruthful — a config file
must not accept a pointer it cannot resolve (ADR 000). A non-env reference is now
refused at parse.

A Keychain (or other) credential store could return later, but only behind a
deliberate decision — not as a half-wired scheme carried on the assumption it
will be finished.
