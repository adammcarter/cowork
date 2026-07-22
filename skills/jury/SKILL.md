---
name: jury
description: Claim-adjudication jury for deciding whether a specific claim has grounds, with adversarial panel reasoning and a durable JURY-VERDICT.md. Use when an agent says a claim should be tested, asks whether a claim is grounded, wants a verdict before relying on an assertion, or invokes "/cowork:jury".
allowed-tools: [Bash, Read, Write, Edit, AskUserQuestion]
---

# Cowork Jury

This skill is the Codex-visible entrypoint for `/cowork:jury`.

Read `../../commands/jury.md` in full and follow it as the runtime contract.
Keep this file thin so the claim scope, panel roles, verdict taxonomy, evidence
ladder, and final reasoning document stay in one source of truth.
