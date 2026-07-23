#!/usr/bin/env python3
"""Host-conformance journeys: one behaviour, performed through a REAL agent CLI.

The generic journeys (journeys.py) prove the contract over raw stdio MCP. These
prove the half that a generic client cannot: that each supported host harness —
Claude Code, Codex, Copilot, OpenCode — actually connects to cowork, accepts its
tool list, and completes a real tool-call round trip through its own MCP stack.

The host is the VARIANT (`uc verify` spawns this once per declared variant).
Every driver registers cowork as a SCOPED MCP server for that single run —
temp project dir, temp COWORK_HOME store — so no user-global host config is
touched, with one documented exception: Copilot merges `--additional-mcp-config`
with the user file, which is additive and per-invocation only.

Assertions read cowork's OWN STORE first (a dispatch record the host caused is
proof no transcript can fake), host stdout second.

Usage: host_journeys.py <row-id> <variant>
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
BINARY = REPO / ".build" / "release" / "cowork"

HOST_BINARIES = {
    "claude": os.path.expanduser("~/.local/bin/claude"),
    "codex": os.path.expanduser("~/.local/bin/codex"),
    "copilot": os.path.expanduser("~/.local/bin/copilot"),
    "opencode": os.path.expanduser("~/.opencode/bin/opencode"),
}

# The model every dispatch row uses: local, free, proven live by the generic
# journeys before this file ever runs.
OMLX_MODEL = "omlx/Ornith-1.0-9B-4bit"

JOURNEYS = {}


def journey(row_id):
    def wrap(fn):
        JOURNEYS[row_id] = fn
        return fn
    return wrap


class Unobserved(Exception):
    """The behaviour was not observed — the variant's finding."""


class PreconditionAbsent(Exception):
    """The variant cannot run here at all (host CLI missing)."""


def require(cond, message):
    if not cond:
        raise Unobserved(message)


def repo_env_keys() -> dict:
    out = {}
    env_file = REPO / ".env"
    if not env_file.exists():
        return out
    for line in env_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        if k.strip() and v.strip():
            out[k.strip()] = v.strip()
    return out


class HostRun:
    """One scoped, headless host invocation with cowork registered."""

    def __init__(self, host: str):
        self.host = host
        self.bin = HOST_BINARIES.get(host, "")
        if not os.path.exists(self.bin):
            raise PreconditionAbsent(f"{host} CLI is not installed at {self.bin}")
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix=f"uc-host-{host}-"))
        self.store = self.dir / "store"
        self.store.mkdir()
        self.proj = self.dir / "proj"
        self.proj.mkdir()
        # The server resolves `env:` credentials from its own environment or a
        # .env beside its cwd; hosts differ in which cwd the server inherits, so
        # pass the key through the server env — the same channel a user's shell
        # export uses.
        self.server_env = {"COWORK_HOME": str(self.store)}
        self.server_env.update(repo_env_keys())

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    # -- per-host drivers --------------------------------------------------

    def run(self, prompt: str, timeout: int = 420) -> str:
        driver = getattr(self, f"_run_{self.host}")
        try:
            out = driver(prompt, timeout)
        except subprocess.TimeoutExpired:
            raise Unobserved(f"{self.host} did not finish within {timeout}s")
        return out

    def _exec(self, cmd, timeout, cwd=None, env=None):
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           cwd=cwd or str(self.proj), env=env)
        if r.returncode != 0:
            raise Unobserved(
                f"{self.host} exited {r.returncode}: "
                f"{(r.stderr or r.stdout).strip()[:300]}")
        return r.stdout + "\n" + r.stderr

    def _run_claude(self, prompt, timeout):
        cfg = self.dir / "mcp.json"
        cfg.write_text(json.dumps({"mcpServers": {"cowork_conformance": {
            "command": str(BINARY), "env": self.server_env}}}))
        return self._exec([
            self.bin, "-p", prompt,
            "--mcp-config", str(cfg), "--strict-mcp-config",
            "--allowedTools", "mcp__cowork_conformance__*",
            "--output-format", "text",
        ], timeout)

    def _run_codex(self, prompt, timeout):
        overrides = [f'mcp_servers.cowork_conformance.command="{BINARY}"']
        for k, v in self.server_env.items():
            overrides.append(f'mcp_servers.cowork_conformance.env.{k}="{v}"')
        # A throwaway CODEX_HOME (auth copied in) is the whole fix: the user's
        # real home carries hooks that stall headless stops and a dozen MCP
        # servers that collide and slow startup. Approval-wise, only the full
        # bypass flag lets a headless run call MCP tools (`approval_policy=
        # "never"` and --full-auto both still cancel them) — acceptable here
        # because everything is disposable: temp cwd, temp store, no repo.
        # Codex names MCP tools mcp__<server>__<tool>; the prompt uses the
        # exact form so the model cannot conclude a dotted name is missing.
        # The last message lands in a file — stdout interleaves noise.
        prompt = prompt.replace("its `capabilities` tool",
                                "its `mcp__cowork_conformance__capabilities` tool") \
                       .replace("its `dispatch` tool",
                                "its `mcp__cowork_conformance__dispatch` tool") \
                       .replace("its `wait` tool",
                                "its `mcp__cowork_conformance__wait` tool") \
                       .replace("its `output` tool",
                                "its `mcp__cowork_conformance__output` tool")
        codex_home = self.dir / "codex-home"
        codex_home.mkdir(exist_ok=True)
        auth = pathlib.Path(os.path.expanduser("~/.codex/auth.json"))
        if not auth.exists():
            raise PreconditionAbsent("codex is not authenticated on this machine")
        shutil.copy(auth, codex_home / "auth.json")
        env = dict(os.environ)
        env["CODEX_HOME"] = str(codex_home)
        last = self.dir / "last.txt"
        cmd = [self.bin, "exec", "--skip-git-repo-check",
               "--dangerously-bypass-approvals-and-sandbox",
               "--output-last-message", str(last)]
        for o in overrides:
            cmd += ["-c", o]
        cmd.append(prompt)
        out = self._exec(cmd, timeout, env=env)
        if last.exists():
            out = last.read_text() + "\n" + out
        return out

    def _run_copilot(self, prompt, timeout):
        cfg = {"mcpServers": {"cowork_conformance": {
            "type": "local", "command": str(BINARY), "tools": ["*"],
            "env": self.server_env}}}
        try:
            out = self._exec([
                self.bin, "-p", prompt,
                "--additional-mcp-config", json.dumps(cfg),
                "--allow-all",
            ], timeout)
        except Unobserved as e:
            if "quota" in str(e).lower() or "AI Credits 0" in str(e):
                # The harness runs but its brain has no quota — the variant's
                # precondition is absent, same class as a missing CLI.
                raise PreconditionAbsent(
                    "copilot has no AI credits / monthly quota exhausted")
            raise
        if "AI Credits 0" in out:
            raise PreconditionAbsent("copilot has no AI credits on this account")
        return out

    def _run_opencode(self, prompt, timeout):
        # `opencode run` never terminates headlessly on this machine (verified:
        # responses complete server-side, nothing is printed, the process
        # idles until killed — with a PTY too). The serve HTTP API is the
        # deterministic driver. The session brain is the local oMLX model, so
        # the variant needs no cloud credential — the same worker the dispatch
        # rows use, worn as the harness's own head.
        import socket
        import urllib.request

        keys = repo_env_keys()
        (self.proj / "opencode.json").write_text(json.dumps({
            "$schema": "https://opencode.ai/config.json",
            "provider": {"omlx": {
                "npm": "@ai-sdk/openai-compatible", "name": "oMLX local",
                "options": {"baseURL": "http://192.168.64.1:8062/v1",
                            "apiKey": keys.get("OMLX_API_KEY", "")},
                "models": {"Ornith-1.0-9B-4bit": {"name": "Ornith 9B"}}}},
            "model": "omlx/Ornith-1.0-9B-4bit",
            "mcp": {"cowork_conformance": {"type": "local",
                                           "command": [str(BINARY)],
                                           "enabled": True,
                                           "environment": self.server_env}},
        }))
        with socket.socket() as s:
            s.bind(("127.0.0.1", 0))
            port = s.getsockname()[1]
        srv = subprocess.Popen([self.bin, "serve", "--port", str(port)],
                               cwd=str(self.proj), stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def api(method, path, body=None, t=timeout):
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}{path}", method=method,
                data=json.dumps(body).encode() if body is not None else None,
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=t) as r:
                return json.loads(r.read())

        try:
            deadline = 20
            for _ in range(deadline):
                try:
                    api("GET", "/session", t=2)
                    break
                except Exception:
                    import time
                    time.sleep(1)
            sid = api("POST", "/session", {})["id"]
            reply = api("POST", f"/session/{sid}/message",
                        {"parts": [{"type": "text", "text": prompt}]})
            err = reply.get("info", {}).get("error")
            require(not err, f"[opencode] the session errored: {json.dumps(err)[:200]}")
            # The final text plus every tool-result the session surfaced — the
            # assertion greps this the same way it greps a CLI transcript.
            msgs = api("GET", f"/session/{sid}/message")
            chunks = []
            for m in msgs:
                for p in m.get("parts", []):
                    if p.get("type") == "text":
                        chunks.append(p.get("text") or "")
                    elif p.get("type") == "tool":
                        chunks.append(json.dumps(p.get("state", {}))[:2000])
            return "\n".join(chunks)
        finally:
            srv.terminate()

    # -- store assertions --------------------------------------------------

    def job_records(self) -> list[dict]:
        jobs = self.store / "jobs"
        if not jobs.exists():
            return []
        out = []
        for j in jobs.iterdir():
            f = j / "job.json"
            if f.exists():
                try:
                    out.append(json.loads(f.read_text()))
                except json.JSONDecodeError:
                    pass
        return out


# ---------------------------------------------------------------------------
# The rows
# ---------------------------------------------------------------------------

@journey("host.conformance.harness_accepts_and_calls_the_contract")
def _(host: str):
    # The cheapest complete proof of connection: the host must accept the tool
    # list (a strict host rejects the whole server on one bad schema) and
    # complete one real tool call through its own MCP stack.
    h = HostRun(host)
    try:
        out = h.run(
            "An MCP server named cowork_conformance is configured in this session. "
            "Call its `capabilities` tool now (no arguments) and print the raw "
            "text it returns. Your harness may expose it under a namespaced "
            "name such as mcp__cowork_conformance__capabilities or "
            "cowork_conformance.capabilities — check your tool list for it "
            "before concluding it is missing. Do not use any other tool.")
        require("workers" in out or "omlx" in out or "backend" in out.lower(),
                f"[{host}] the capabilities call's result never surfaced; "
                f"host output: {out.strip()[:300]!r}")
        print(f"[{host}] accepted the tool list and completed a capabilities call")
    finally:
        h.cleanup()


@journey("host.conformance.dispatch_roundtrip_through_the_harness")
def _(host: str):
    # The golden path a user actually runs: dispatch -> wait -> output, driven
    # by the host's own agent loop against a real local worker. The store is
    # the arbiter: a succeeded record in a store only this run can write is
    # proof the host caused a real dispatch.
    h = HostRun(host)
    try:
        out = h.run(
            "An MCP server named cowork_conformance is configured in this session. Perform exactly these steps: "
            f"1) call its `dispatch` tool with task='Reply with exactly: HOST_OK' "
            f"and backend='{OMLX_MODEL}' — it returns a job id. "
            "2) call its `wait` tool with that id and timeout='120'. "
            "3) call its `output` tool with that id. "
            "Then print the worker's reply verbatim.")
        records = h.job_records()
        require(records, f"[{host}] no dispatch record exists in this run's "
                         "store — the host never actually called dispatch")
        states = {r.get("state") for r in records}
        diags = [d for r in records for d in (r.get("diagnostics") or [])]
        require("succeeded" in states,
                f"[{host}] dispatch record states: {sorted(states)}; "
                f"diagnostics: {diags}; host output: {out.strip()[:160]!r}")
        require("HOST_OK" in out,
                f"[{host}] the worker's answer never reached the host's reply: "
                f"{out.strip()[:300]!r}")
        print(f"[{host}] dispatch->wait->output round trip: record succeeded, "
              f"answer surfaced")
    finally:
        h.cleanup()


def main():
    if len(sys.argv) != 3:
        print("usage: host_journeys.py <row-id> <variant>", file=sys.stderr)
        return 2
    row, variant = sys.argv[1], sys.argv[2]
    fn = JOURNEYS.get(row)
    if fn is None:
        print(f"no host journey for row {row}", file=sys.stderr)
        return 1
    try:
        fn(variant)
        return 0
    except PreconditionAbsent as e:
        print(f"PRECONDITION ABSENT: {e}", file=sys.stderr)
        return 3
    except Unobserved as e:
        print(f"FAILED: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
