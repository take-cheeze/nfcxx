"""OpenVINO census: decoded vs unknown bytes of shave.text over all blobs (self-contained, no import side effects)."""
import glob, struct, sys, time, collections
from decode_generic import decode


def shave_text(path):
    b = open(path, "rb").read()
    try:
        so = struct.unpack_from("<Q", b, 0x28)[0]
        n = struct.unpack_from("<H", b, 0x3C)[0]
        si = struct.unpack_from("<H", b, 0x3E)[0]
        H = [struct.unpack_from("<IIQQQQIIQQ", b, so + 64 * i) for i in range(n)]
    except Exception:
        return None
    nm = lambda o: b[H[si][4] + o:].split(b"\0")[0].decode(errors="replace")
    for h in H:
        if nm(h[0]) == "shave.text":
            return b[h[4]:h[4] + h[5]]
    return None


files = sorted(set(glob.glob("/home/takecheeze/ov-eval/*.blob")))
tot = unk = blobs = clean = 0
first = collections.Counter()
t0 = time.time()
for i, p in enumerate(files, 1):
    t = shave_text(p)
    if not t:
        continue
    t = t.rstrip(b"\0")
    if not t:
        continue
    pos = 0
    bad = 0
    for txt, n in decode(t):
        if txt == "??":
            if bad == 0:
                first[t[pos]] += 1
            bad += n
        pos += n
    tot += len(t)
    unk += bad
    blobs += 1
    clean += (bad == 0)
    print("%3d %-40s %8d bytes  unknown %6d  (%.1fs)" % (i, p.split("/")[-1][:40], len(t), bad, time.time() - t0),
          flush=True)
print("blobs:", blobs, "bytes:", tot, "unknown:", unk,
      "coverage: %.1f%%" % (100.0 * (tot - unk) / max(tot, 1)))
print("blobs fully decoded:", clean)
for k, c in first.most_common(12):
    print("  first-fail byte %02x  x%d" % (k, c))
