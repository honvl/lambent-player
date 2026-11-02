"""A stand-in for Lambent Server's licence routes, for trying the app's Lambent Enhance screens before the server has them.

    python3 tool/fake_licence_proxy.py --upstream http://goldenchocobo.local:47800 --port 47801 --state none

Answers `GET /v1/licence` and `POST /v1/licence/store` (ENTITLEMENTS.md section 7) itself and passes every other request to
the upstream Lambent Server, so the app can sign in and browse through it. A forwarded purchase turns the state to `active`
and is logged; `--fail-store 502` answers store forwards with that status instead, to check that the app keeps the
transaction unfinished.
"""
import argparse, json, socket, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("--upstream", required=True)
ap.add_argument("--port", type=int, default=47801)
ap.add_argument("--state", default="none", choices=["active", "trial", "preview", "none"])
ap.add_argument("--fail-store", type=int, default=0)
args = ap.parse_args()

licence = {
    "enhance": {"state": args.state, "until_ms": None, "source": None},
    "pro_on_this_household": False,
    "buy_url": "https://getlambent.vercel.app/buy?household=FAKE",
}
if args.state in ("active", "trial"):
    licence["enhance"]["until_ms"] = int(time.time() * 1000) + 14 * 86400_000


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        req = urllib.request.Request(args.upstream + self.path, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() not in ("host", "content-length", "connection", "accept-encoding"):
                req.add_header(k, v)
        try:
            resp = urllib.request.urlopen(req, timeout=60)
            status, headers, data = resp.status, resp.headers, resp.read()
        except urllib.error.HTTPError as e:
            status, headers, data = e.code, e.headers, e.read()
        # The server names its own address in some answers; the app should keep using this one.
        data = data.replace(args.upstream.encode(), f"http://{self.headers.get('Host')}".encode())
        self.send_response(status)
        for k, v in headers.items():
            if k.lower() not in ("content-length", "transfer-encoding", "connection"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.split("?")[0] == "/v1/licence":
            return self._json(200, licence)
        self._proxy()

    def do_POST(self):
        if self.path.split("?")[0] == "/v1/licence/store":
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            print("FORWARDED", json.dumps({k: (v[:40] + "…" if isinstance(v, str) and len(v) > 40 else v) for k, v in body.items()}), flush=True)
            if args.fail_store:
                return self._json(args.fail_store, {"error": "service_unreachable", "message": "The licence service could not be reached."})
            licence["enhance"] = {"state": "active", "until_ms": int(time.time() * 1000) + 30 * 86400_000, "source": body.get("store")}
            return self._json(200, licence)
        self._proxy()

    do_DELETE = do_PUT = _proxy


class DualStackServer(ThreadingHTTPServer):
    # IPv6 and IPv4 on one socket: a simulator's "localhost" is ::1.
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


DualStackServer(("::", args.port), Handler).serve_forever()
