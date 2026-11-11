#!/usr/bin/env python3
"""A mock of the GitHub Actions cache service (the v2 Results API calls scripts/nfcxx-cache-gha.py makes), for tests.
It keeps entries in memory and checks what the client must send: the bearer token, the protobuf fields, the PATCH with
Content-Range, and the size at finalize. Entries are immutable, as the real service's are. Usage: mock_results.py TOKEN
Prints the base URL on its first line, then serves until it is killed."""
import http.server
import socketserver
import sys
import threading
import uuid

import importlib.util
import os

# The helper's protobuf codec is reused here, so the test checks the wire format both ways.
_spec = importlib.util.spec_from_file_location(
    "nfcxx_cache_gha", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "nfcxx-cache-gha.py"))
c = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(c)

TOKEN = sys.argv[1]
ENTRIES = {}    # (key, version) -> {"id": str, "data": bytes or None, "final": bool}
BLOBS = {}      # id -> bytes
LOCK = threading.Lock()
SERVICE = "/" + c.SERVICE


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body=b"", ctype="application/protobuf"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def _auth_ok(self):
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def do_POST(self):
        if not self.path.startswith(SERVICE):
            return self._send(404)
        if not self._auth_ok():
            return self._send(401, b'{"code":"unauthenticated"}', "application/json")
        if self.headers.get("Accept") != c.ACCEPT:
            return self._send(400, b'{"code":"invalid_argument","msg":"Accept"}', "application/json")
        method = self.path[len(SERVICE):]
        f = c._pb_decode(self._body())
        key = f.get(2, [b""])[0].decode()
        version = f.get(4 if method in ("FinalizeCacheEntryUpload", "GetCacheEntryDownloadURL") else 3, [b""])[0].decode()
        if method == "FinalizeCacheEntryUpload" and 4 not in f:
            return self._send(400)
        with LOCK:
            ent = ENTRIES.get((key, version))
            if method == "CreateCacheEntry":
                if ent is not None:
                    return self._send(200, c._pb_int(1, 0) + c._pb_str(3, "exists"))
                eid = uuid.uuid4().hex
                ENTRIES[(key, version)] = {"id": eid, "data": None, "final": False}
                return self._send(200, c._pb_int(1, 1) + c._pb_str(2, f"{BASE}/blob/{eid}"))
            if method == "FinalizeCacheEntryUpload":
                size = f.get(3, [-1])[0]
                if ent is None or ent["data"] is None or len(ent["data"]) != size:
                    return self._send(200, c._pb_int(1, 0))
                ent["final"] = True
                return self._send(200, c._pb_int(1, 1) + c._pb_int(2, 1))
            if method == "GetCacheEntryDownloadURL":
                if ent is None or not ent["final"]:
                    return self._send(200, c._pb_int(1, 0))
                return self._send(200, c._pb_int(1, 1) + c._pb_str(2, f"{BASE}/blob/{ent['id']}"))
        return self._send(404)

    def do_PATCH(self):
        if not self.path.startswith("/blob/"):
            return self._send(404)
        data = self._body()
        eid = self.path[len("/blob/"):]
        rng = self.headers.get("Content-Range", "")
        n = len(data)
        if rng != f"bytes 0-{n - 1}/{n}":
            return self._send(400, b"bad Content-Range", "text/plain")
        with LOCK:
            owner = next((e for e in ENTRIES.values() if e["id"] == eid), None)
            if owner is None or owner["data"] is not None:
                return self._send(409, b"no reservation", "text/plain")
            owner["data"] = data
        return self._send(201)

    def do_GET(self):
        if not self.path.startswith("/blob/"):
            return self._send(404)
        eid = self.path[len("/blob/"):]
        with LOCK:
            owner = next((e for e in ENTRIES.values() if e["id"] == eid and e["final"]), None)
        if owner is None:
            return self._send(404, b"", "text/plain")
        return self._send(200, owner["data"], "application/octet-stream")


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


server = Server(("127.0.0.1", 0), Handler)
BASE = f"http://127.0.0.1:{server.server_address[1]}"
print(BASE, flush=True)
server.serve_forever()
