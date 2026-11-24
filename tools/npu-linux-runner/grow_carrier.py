"""Grow the SHAVE code window of an OpenVINO NPU blob (ELF64 + OVNPU trailer), as npu-render's
grow_frame_carrier.py does for its pinned Windows carrier. Differences, all needed for blobs exported on
Linux: the number of range rows is read from each section's size (1 or 2 rows, 40 bytes each), and no
sha256 pin is checked. Nothing else in the blob changes, and the result is validated by the OpenVINO
loader when the blob is imported.

usage: grow_text.py <in.blob> <out.blob> <window_bytes>
"""
import struct
import sys

SHDR = "<IIQQQQIIQQ"
NOBITS = 8
ROW = 40
RANGE_SIZE_OFFSET = 24
TRAILER_MAGIC = b"OVNPU"


def check(ok, message):
    if not ok:
        raise ValueError(message)


def split_trailer(blob):
    check(blob.endswith(TRAILER_MAGIC) and len(blob) > 13, "OpenVINO NPU trailer")
    (size,) = struct.unpack_from("<Q", blob, len(blob) - 13)
    check(0 < size <= len(blob) - 13 and size % 4096 == 0, "trailer data size")
    return blob[:size], blob[size : len(blob) - 13]


def grow_text(elf, window):
    check(elf[:6] == b"\x7fELF\x02\x01", "ELF64 little-endian")
    (shoff,) = struct.unpack_from("<Q", elf, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", elf, 0x3A)
    check(shentsize == 64 and shoff == 0x40 and 0 < shnum < 8192, "section header table")
    headers = [list(struct.unpack_from(SHDR, elf, shoff + i * 64)) for i in range(shnum)]
    strings = headers[shstrndx]

    def name(h):
        at = strings[4] + h[0]
        return elf[at : elf.index(b"\0", at)].decode("ascii")

    names = [name(h) for h in headers]
    text = names.index("shave.text")
    offset, size, align = headers[text][4], headers[text][5], headers[text][8]
    check(window % align == 0, "window alignment")
    later = sorted(h[4] for h in headers if h[1] != NOBITS and h[4] > offset)
    region = later[0] - offset
    check(window > region and size <= region, "growing text")
    delta = window - region
    for h in headers:
        if h[1] != NOBITS and h[4] > offset:
            h[4] += delta
    headers[text][5] = size + delta
    out = bytearray(elf[: offset + size] + bytes(window - size) + elf[later[0] :])
    for i, h in enumerate(headers):
        struct.pack_into(SHDR, out, shoff + i * 64, *h)
    code = None
    for i, h in enumerate(headers):
        if not names[i].startswith("task.shave.range."):
            continue
        check(h[5] % ROW == 0 and h[5] > 0, "range rows")
        for row in range(h[5] // ROW):
            at = h[4] + row * ROW + RANGE_SIZE_OFFSET
            (old,) = struct.unpack_from("<I", out, at)
            check(code in (None, old) and 0 < old <= size, "range code size")
            code = old
            struct.pack_into("<I", out, at, old + delta)
    check(code is not None, "range descriptors")
    return bytes(out), code + delta


def grow(blob, window):
    elf, metadata = split_trailer(blob)
    grown, code_bytes = grow_text(elf, window)
    body = grown.rstrip(b"\0")
    padded = body + bytes((len(body) + 4095) // 4096 * 4096 - len(body))
    return padded + metadata + struct.pack("<Q", len(padded)) + TRAILER_MAGIC, code_bytes


if __name__ == "__main__":
    src, dst, window = sys.argv[1], sys.argv[2], int(sys.argv[3])
    grown, code = grow(open(src, "rb").read(), window)
    open(dst, "wb").write(grown)
    print(f"wrote {dst}: {len(grown)} bytes, code window {code} bytes")
