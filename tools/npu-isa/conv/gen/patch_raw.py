import struct, sys
dst, rawtext, out = sys.argv[1], sys.argv[2], sys.argv[3]
b = open(dst, "rb").read()
so = struct.unpack_from("<Q", b, 0x28)[0]
n = struct.unpack_from("<H", b, 0x3C)[0]
si = struct.unpack_from("<H", b, 0x3E)[0]
H = [struct.unpack_from("<IIQQQQIIQQ", b, so + 64 * i) for i in range(n)]
nm = lambda o: b[H[si][4] + o:].split(b"\0")[0].decode()
doff = dsz = None
for h in H:
    if nm(h[0]) == "shave.text":
        doff, dsz = h[4], h[5]
code = open(rawtext, "rb").read()
assert len(code) <= dsz, (len(code), dsz)
bb = bytearray(b)
bb[doff:doff+dsz] = code + b"\0" * (dsz - len(code))
open(out, "wb").write(bb)
print("patched", out, "text slot", dsz, "code", len(code))
