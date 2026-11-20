import struct


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
