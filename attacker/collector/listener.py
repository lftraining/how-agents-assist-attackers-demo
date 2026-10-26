#!/usr/bin/env python3
"""Local-only collector for the agents-assist-attackers demo (INERT infrastructure, NOT payload).

Listens for HTTP requests on the LOCAL container telemetry.corewave.test (:80) and prints
each POST body to stdout (`docker logs collector`), so you can see the moment an agent is
steered (by the poisoned vendor doc) into exfiltrating the synthetic decoy credential.

It is deliberately dumb and safe:
  * it binds a LOCAL socket only — the container joins the kind Docker network and publishes
    no host port (see attacker/start-attacker.sh) — and makes NO outbound connection of any kind;
  * it logs ONLY a timestamp, the request method, the request path, and the POST body. It never
    logs request headers, so an Authorization / x-api-key header can never surface a secret on
    the screen;
  * it stores nothing to disk and forwards nothing anywhere.

Standard library only; no dependencies.
"""
import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# All of the container's own interfaces. No port is published on your machine.
BIND_ADDR = "0.0.0.0"
PORT = 80
MAX_BODY = 65536  # a size cap, so an oversized body cannot exhaust memory


def _stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


class CollectorHandler(BaseHTTPRequestHandler):
    # Turn off the default access log; do_POST prints its own record.
    def log_message(self, *args):  # noqa: D401
        pass

    def _read_body(self):
        try:
            length = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            length = 0
        length = max(0, min(length, MAX_BODY))
        return self.rfile.read(length) if length else b""

    def _respond(self, code=200, text=b"received\n"):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(text)))
        self.end_headers()
        self.wfile.write(text)

    def do_POST(self):
        body = self._read_body()
        # Log the time, method, path, and body only, never the headers.
        print("=" * 64, flush=True)
        print("[%s] COLLECTOR received %s %s" % (_stamp(), self.command, self.path), flush=True)
        print("---- body ----", flush=True)
        print(body.decode("utf-8", "replace"), flush=True)
        print("=" * 64, flush=True)
        self._respond(200)

    # Treat PUT the same as POST.
    do_PUT = do_POST

    def do_GET(self):
        # The readiness check's liveness probe.
        self._respond(200, b"collector up\n")


if __name__ == "__main__":
    print("[%s] collector listening on %s:%d (local only; logs POST bodies to stdout)"
          % (_stamp(), BIND_ADDR, PORT), flush=True)
    ThreadingHTTPServer((BIND_ADDR, PORT), CollectorHandler).serve_forever()
