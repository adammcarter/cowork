"""A minimal MCP stdio client for driving the real cowork binary.

This exists so every acceptance row is a *performed run* against the shipped
artifact over its real transport, rather than a unit test of an internal type or
a plan describing what would happen. Nothing here imports CoworkCore; the only
surface touched is the one a host CLI touches.
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import threading
import time

REPO = pathlib.Path(__file__).resolve().parents[3]
BINARY = REPO / ".build" / "release" / "cowork"


def repo_env_keys() -> dict:
    """Read .env beside the package. Values are never printed by this harness."""
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


class CoworkFailure(Exception):
    pass


class Cowork:
    """One cowork server process, driven over stdio exactly as a host CLI drives it."""

    def __init__(self, home: pathlib.Path, cwd: pathlib.Path, store: pathlib.Path,
                 extra_env: dict | None = None, inherit_home: bool = False):
        self.home = pathlib.Path(home)
        self.cwd = pathlib.Path(cwd)
        self.store = pathlib.Path(store)
        self._id = 0
        self._lock = threading.Lock()

        env = dict(os.environ)
        if not inherit_home:
            env["HOME"] = str(self.home)
        env["COWORK_HOME"] = str(self.store)
        env.update(repo_env_keys())
        if extra_env:
            env.update(extra_env)
        self.env = env

        if not BINARY.exists():
            raise CoworkFailure(
                f"the cowork binary is not built at {BINARY}; run: swift build -c release")

        self.proc = subprocess.Popen(
            [str(BINARY)],
            cwd=str(self.cwd),
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )

    # -- lifecycle ---------------------------------------------------------

    def start(self):
        """Perform the MCP handshake. Raises if the server refused to start."""
        try:
            self._request("initialize", {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "use-cases", "version": "1"},
            })
        except CoworkFailure:
            raise
        self._notify("notifications/initialized")
        return self

    def stop(self):
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=5)

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()

    def stderr_text(self) -> str:
        try:
            return self.proc.stderr.read() or ""
        except Exception:
            return ""

    # -- jsonrpc -----------------------------------------------------------

    def _write(self, obj):
        if self.proc.poll() is not None:
            raise CoworkFailure(
                f"cowork exited (code {self.proc.returncode}) before the request: "
                f"{self.stderr_text().strip()}")
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def _notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def _request(self, method, params=None, timeout=180):
        with self._lock:
            self._id += 1
            rid = self._id
            self._write({"jsonrpc": "2.0", "id": rid, "method": method,
                         "params": params or {}})
            deadline = time.time() + timeout
            while time.time() < deadline:
                line = self.proc.stdout.readline()
                if not line:
                    code = self.proc.poll()
                    raise CoworkFailure(
                        f"cowork closed stdout (exit {code}) awaiting {method}: "
                        f"{self.stderr_text().strip()}")
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if msg.get("id") == rid:
                    if "error" in msg:
                        raise CoworkFailure(f"{method} -> jsonrpc error: {msg['error']}")
                    return msg.get("result", {})
            raise CoworkFailure(f"timed out after {timeout}s awaiting a reply to {method}")

    # -- the ten tools -----------------------------------------------------

    def list_tools(self) -> list[str]:
        res = self._request("tools/list")
        return [t["name"] for t in res.get("tools", [])]

    def list_tools_raw(self) -> list[dict]:
        """Full tool objects, including inputSchema — so a journey can assert the
        schema shape a strict MCP host (Claude Code) validates."""
        return self._request("tools/list").get("tools", [])

    def call(self, name, _timeout=180, **arguments):
        """Call a tool. Returns (text, is_error) — both, because an error IS a result.

        The transport budget is `_timeout` (underscored) so it cannot collide
        with a tool's own `timeout` argument, which `wait` really has.
        """
        res = self._request("tools/call",
                            {"name": name, "arguments": {k: str(v) for k, v in arguments.items()}},
                            timeout=_timeout)
        text = "".join(c.get("text", "") for c in res.get("content", []))
        return text, bool(res.get("isError", False))

    def ok(self, name, _timeout=180, **arguments):
        """Call a tool that must succeed. Raises on a declared error."""
        text, is_error = self.call(name, _timeout=_timeout, **arguments)
        if is_error:
            raise CoworkFailure(f"{name} unexpectedly failed: {text}")
        return text

    def dispatch(self, task, backend, **kw):
        return self.ok("dispatch", task=task, backend=backend, **kw)

    def status(self, id):
        return self.ok("status", id=id)

    def output(self, id):
        return self.ok("output", id=id)

    def wait(self, id, timeout=60):
        # `timeout` is the tool's own blocking budget; the transport is given
        # slack on top so a transport timeout can never be mistaken for the
        # tool's hard cap.
        return self.ok("wait", _timeout=timeout + 30, id=id, timeout=timeout)

    def wait_terminal(self, id, budget=240):
        """Poll wait() until the dispatch reaches a terminal state or the budget expires.

        Terminal, not 'done-ish': silence is the one forbidden outcome, so this
        returns only a real terminal state or raises.
        """
        terminal = {"succeeded", "failed", "cancelled", "timed_out"}
        deadline = time.time() + budget
        state = self.status(id)
        while time.time() < deadline:
            if state.split()[0] in terminal:
                return state
            state = self.wait(id, timeout=min(20, max(1, int(deadline - time.time()))))
            if state.split()[0] in terminal:
                return state
            state = self.status(id)
        raise CoworkFailure(
            f"dispatch {id} never reached a terminal state within {budget}s (last: {state})")

    # -- event stream ------------------------------------------------------

    def events(self) -> list[dict]:
        stream = self.store / "events.ndjson"
        if not stream.exists():
            return []
        out = []
        for line in stream.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                raise CoworkFailure(f"event stream has a non-JSON line: {line!r}")
        return out

    def events_for(self, id) -> list[dict]:
        return [e for e in self.events() if e.get("id") == id]


GLOBAL_CONFIG = pathlib.Path(NSHOME := os.path.expanduser("~")) / ".cowork" / "config.toml"


class Fixture:
    """A throwaway project directory + store for one performed run.

    A note that is itself a finding: this fixture CANNOT supply its own global
    config. `~/.cowork/config.toml` is resolved through `NSHomeDirectory()`,
    which on Darwin reads the password database and ignores `$HOME`, and cowork
    exposes no override. `COWORK_HOME` redirects the *store* only. So the store
    and the project config are isolated per run, while the provider set is
    necessarily the real one on this machine. Rows that depend on a provider
    therefore state that dependency, and a row needing a provider that is not
    configured here is recorded as unverifiable rather than faked.
    """

    def __init__(self, project_config: str | None = None, with_keys: bool = True):
        self.dir = pathlib.Path(tempfile.mkdtemp(prefix="uc-cowork-"))
        self.proj = self.dir / "proj"
        self.store = self.dir / "store"
        self.proj.mkdir(parents=True)
        self.store.mkdir(parents=True)
        if project_config is not None:
            (self.proj / "cowork.toml").write_text(project_config)
        # A dispatch resolves `env:` credentials only via a `.env` beside the
        # cwd (see the credential-propagation row), so a fixture that needs a
        # working credential must place one here.
        if with_keys:
            self.write_env(repo_env_keys())

    def write_env(self, keys: dict):
        (self.proj / ".env").write_text("".join(f"{k}={v}\n" for k, v in keys.items()))

    def server(self, **kw) -> Cowork:
        return Cowork(home=pathlib.Path.home(), cwd=self.proj, store=self.store,
                      inherit_home=True, **kw)

    def cleanup(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.cleanup()


def global_providers() -> dict:
    """The provider/cli names the real global config declares.

    Read here so a row can state honestly WHY it could not run, instead of
    failing with a confusing 'no such backend'.
    """
    import re
    names = {"provider": [], "profile": [], "cli": []}
    if not GLOBAL_CONFIG.exists():
        return names
    for m in re.finditer(r"^\[(provider|profile|cli)\.([^\]]+)\]",
                         GLOBAL_CONFIG.read_text(), re.M):
        names[m.group(1)].append(m.group(2))
    return names


def require_provider(name: str):
    have = global_providers()
    if name not in have["provider"] and name not in have["cli"]:
        raise Unverifiable(
            f"provider '{name}' is not declared in {GLOBAL_CONFIG}, and cowork offers no "
            f"way to point at an alternate global config (NSHomeDirectory ignores $HOME). "
            f"Declared: providers={have['provider']} cli={have['cli']}")


class Unverifiable(Exception):
    """This row's precondition is genuinely absent right now.

    Raised — never swallowed — so the row fails loudly with the reason rather
    than being quietly marked green. An unverifiable row is information.
    """


OMLX_MODEL = "omlx/example-7b"


def require(condition, message):
    if not condition:
        raise CoworkFailure(message)
