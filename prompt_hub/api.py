from __future__ import annotations

import json
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

from .logger import log_prompt, query_prompts


class PromptHubHandler(BaseHTTPRequestHandler):
    def _send(self, status: int, payload: dict):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            return self._send(200, {"ok": True})
        if parsed.path == "/prompts":
            qs = parse_qs(parsed.query)
            limit = int(qs.get("limit", ["200"])[0])
            channel = qs.get("channel", [None])[0]
            chat_id = qs.get("chat_id", [None])[0]
            q = qs.get("q", [None])[0]
            rows = query_prompts(limit=limit, channel=channel, chat_id=chat_id, q=q)
            data = [dict(r) for r in rows]
            return self._send(200, {"count": len(data), "items": data})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/log":
            return self._send(404, {"error": "not found"})

        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            body = json.loads(raw.decode("utf-8"))
        except Exception:
            return self._send(400, {"error": "invalid json"})

        if not body.get("ts_utc") or not body.get("prompt_text"):
            return self._send(400, {"error": "ts_utc and prompt_text are required"})

        row_id = log_prompt(
            ts_utc=body["ts_utc"],
            prompt_text=body["prompt_text"],
            source=body.get("source", "unknown"),
            channel=body.get("channel"),
            chat_id=body.get("chat_id"),
            session_id=body.get("session_id"),
            author=body.get("author"),
        )
        return self._send(201, {"ok": True, "id": row_id})


def run(host: str = "0.0.0.0", port: int = 8787):
    server = HTTPServer((host, port), PromptHubHandler)
    print(f"PromptHub API listening on http://{host}:{port}")
    server.serve_forever()


if __name__ == "__main__":
    run()
