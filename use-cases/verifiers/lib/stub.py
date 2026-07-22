"""A controllable OpenAI-compatible provider, served over real HTTP.

Why this is legitimate acceptance evidence, and where its limit is.

Some states a caller will really meet cannot be *staged* against a live model on
demand: a provider replying `finish_reason: length`, or answering 429 with
"Insufficient balance". Waiting for z.ai's balance to run out is not a test
strategy. So the provider is staged instead — and everything under test stays
real: the shipped binary, a real TCP socket, real HTTP, real JSON, cowork's real
config resolution and its real agent loop.

What this proves is cowork's behaviour when a provider says a given thing. What
it does NOT prove is that any particular vendor says it — so a row that can be
run against a real provider is, and only rows about cowork's own reaction to a
provider's declaration use a stub. A stub is declared as such in its row.

This is exactly the ADR 005 claim in action: a provider is configuration. If a
stub can be dropped in as a provider with no code change, the claim holds.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer


class StubProvider:
    """One-shot configurable endpoint. Use as a context manager; `base_url` is real."""

    def __init__(self, status=200, body=None, finish_reason="stop",
                 content="stub", delay=0.0):
        self.status = status
        self.finish_reason = finish_reason
        self.content = content
        self.delay = delay
        self.body = body
        self.requests = []
        self.headers_seen = []

        stub = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(self):
                import time as _t
                length = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(length)
                try:
                    stub.requests.append(json.loads(raw))
                except Exception:
                    stub.requests.append({"<unparsed>": raw.decode("utf-8", "replace")})
                stub.headers_seen.append(dict(self.headers))
                if stub.delay:
                    _t.sleep(stub.delay)
                payload = stub.body if stub.body is not None else {
                    "choices": [{
                        "message": {"role": "assistant", "content": stub.content},
                        "finish_reason": stub.finish_reason,
                    }]
                }
                data = json.dumps(payload).encode()
                self.send_response(stub.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_port
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def project_config(self, name="stub") -> str:
        """A project-declared provider. It names no credential, so the ADR 005
        refusal rule leaves it alone — which is why a stub can be project-local."""
        return (f"[provider.{name}]\n"
                f'kind     = "openai_compatible"\n'
                f'base_url = "{self.base_url}"\n')

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.server.shutdown()
        self.server.server_close()
