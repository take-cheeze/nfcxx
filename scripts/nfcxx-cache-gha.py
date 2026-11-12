#!/usr/bin/env python3
"""Stores and fetches one nfcxx compile-cache entry in the GitHub Actions cache service (cache v2, the protocol sccache's
GHA backend uses through OpenDAL). Standard library only; run it with `python3 -I`.

  nfcxx-cache-gha.py get KEY DIR           extracts the entry KEY into DIR (created). Exit 0: hit. Exit 1: miss.
  nfcxx-cache-gha.py put KEY DIR FILE...   stores FILE... (paths relative to DIR) as the entry KEY. Exit 0: stored, or the
                                           key already exists (GHA entries are immutable). Exit 2: an error.

The entry is a tar of the named files. Its cache key is "nfcxx-<KEY>" and its version is the SHA-256 of NAMESPACE, so a
change to NAMESPACE drops every entry. The service comes from ACTIONS_RESULTS_URL and ACTIONS_RUNTIME_TOKEN (set in a
workflow step that runs with the cache enabled; ACTIONS_CACHE_SERVICE_V2 must be set too, or the runner uses v1).

Wire format (from the actions/toolkit generated types and OpenDAL's ghac service): Twirp POSTs with protobuf bodies to
  twirp/github.actions.results.api.v1.CacheService/{CreateCacheEntry,FinalizeCacheEntryUpload,GetCacheEntryDownloadURL}
CreateCacheEntry returns a signed upload URL, which takes the blob with PATCH and a Content-Range header. Finalize
commits the size. GetCacheEntryDownloadURL returns a signed URL that is read with GET.
"""
import hashlib
import io
import os
import re
import sys
import tarfile
import urllib.error
import urllib.request

NAMESPACE = "nfcxx-cache-v1"
SERVICE = "twirp/github.actions.results.api.v1.CacheService/"
ACCEPT = "application/json;api-version=6.0-preview.1"
KEY_RE = re.compile(r"^[A-Za-z0-9._-]{1,200}$")


class CacheError(Exception):
    pass


# --- protobuf (only what these messages use: varints and length-delimited strings/bytes) ---

def _varint(n):
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _pb_str(field, s):
    data = s.encode() if isinstance(s, str) else s
    return _varint((field << 3) | 2) + _varint(len(data)) + data


def _pb_int(field, n):
    return _varint((field << 3) | 0) + _varint(n)


def _pb_decode(buf):
    """Returns {field: [value, ...]}; a varint is an int, a length-delimited field is bytes."""
    out = {}
    i = 0
    while i < len(buf):
        tag = 0
        shift = 0
        while True:
            b = buf[i]
            i += 1
            tag |= (b & 0x7F) << shift
            shift += 7
            if not b & 0x80:
                break
        field, wire = tag >> 3, tag & 7
        if wire == 0:
            val = 0
            shift = 0
            while True:
                b = buf[i]
                i += 1
                val |= (b & 0x7F) << shift
                shift += 7
                if not b & 0x80:
                    break
        elif wire == 2:
            n = 0
            shift = 0
            while True:
                b = buf[i]
                i += 1
                n |= (b & 0x7F) << shift
                shift += 7
                if not b & 0x80:
                    break
            val = bytes(buf[i:i + n])
            i += n
        else:
            raise CacheError(f"unsupported protobuf wire type {wire}")
        out.setdefault(field, []).append(val)
    return out


# --- the service ---

class Service:
    def __init__(self):
        base = os.environ.get("ACTIONS_RESULTS_URL", "")
        token = os.environ.get("ACTIONS_RUNTIME_TOKEN", "")
        if not base or not token:
            raise CacheError("ACTIONS_RESULTS_URL and ACTIONS_RUNTIME_TOKEN are not set (not in a workflow step with the cache)")
        self.base = base.rstrip("/") + "/"
        self.token = token
        self.version = hashlib.sha256(NAMESPACE.encode()).hexdigest()

    def _call(self, method, body):
        req = urllib.request.Request(self.base + SERVICE + method, data=body, method="POST", headers={
            "Authorization": f"Bearer {self.token}", "Content-Type": "application/protobuf", "Accept": ACCEPT,
            "Content-Length": str(len(body))})
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return _pb_decode(resp.read())
        except urllib.error.HTTPError as e:
            raise CacheError(f"{method}: HTTP {e.code} {e.read()[:300]!r}")

    def _key(self, key):
        return "nfcxx-" + key

    def download_url(self, key):
        """The signed download URL of KEY, or None when the entry is absent."""
        resp = self._call("GetCacheEntryDownloadURL", _pb_str(2, self._key(key)) + _pb_str(4, self.version))
        if not resp.get(1, [0])[0]:
            return None
        return resp[2][0].decode()

    def reserve(self, key):
        """A signed upload URL for a new entry, or None when the key already exists."""
        resp = self._call("CreateCacheEntry", _pb_str(2, self._key(key)) + _pb_str(3, self.version))
        if not resp.get(1, [0])[0]:
            return None
        return resp[2][0].decode()

    def finalize(self, key, size):
        resp = self._call("FinalizeCacheEntryUpload",
                          _pb_str(2, self._key(key)) + _pb_int(3, size) + _pb_str(4, self.version))
        if not resp.get(1, [0])[0]:
            raise CacheError("FinalizeCacheEntryUpload returned not ok")


def _http(method, url, body=None, headers=None):
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return resp.read()


def _pack(src_dir, names):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        for name in names:
            path = os.path.join(src_dir, name)
            if not os.path.isfile(path):
                raise CacheError(f"{path} is not a file")
            tar.add(path, arcname=name, recursive=False)
    return buf.getvalue()


def _unpack(data, dest):
    os.makedirs(dest, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r") as tar:
        if hasattr(tarfile, "data_filter"):
            tar.extractall(dest, filter="data")
        else:  # Python without the extraction filters: entries are plain files named at the top level
            for m in tar.getmembers():
                if not m.isfile() or "/" in m.name or m.name in ("", ".", ".."):
                    raise CacheError(f"unexpected entry {m.name!r}")
            tar.extractall(dest)


def get(key, dest):
    svc = Service()
    url = svc.download_url(key)
    if url is None:
        return 1
    data = _http("GET", url)
    _unpack(data, dest)
    return 0


def put(key, src_dir, names):
    svc = Service()
    data = _pack(src_dir, names)
    url = svc.reserve(key)
    if url is None:
        return 0   # already stored (entries are immutable): nothing to do
    n = len(data)
    _http("PATCH", url, body=data, headers={
        "Content-Type": "application/octet-stream", "Content-Length": str(n),
        "Content-Range": f"bytes 0-{n - 1}/{n}"})
    svc.finalize(key, n)
    return 0


def main(argv):
    if len(argv) < 4 or argv[1] not in ("get", "put"):
        print(__doc__, file=sys.stderr)
        return 2
    cmd, key, path = argv[1], argv[2], argv[3]
    if not KEY_RE.match(key):
        print(f"nfcxx-cache-gha: bad key {key!r}", file=sys.stderr)
        return 2
    try:
        if cmd == "get":
            return get(key, path)
        if len(argv) < 5:
            print("nfcxx-cache-gha: put needs at least one FILE", file=sys.stderr)
            return 2
        return put(key, path, argv[4:])
    except (CacheError, OSError, tarfile.TarError, IndexError, UnicodeDecodeError) as e:
        print(f"nfcxx-cache-gha: {cmd} {key}: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
