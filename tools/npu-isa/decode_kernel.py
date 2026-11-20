"""Decode a generated add-kernel text (NPU 5000 SHAVE, linked .text bytes) back to assembly.

Single ops: matched against learned templates (table.json, kernel_table.json) using fixed bits,
operands extracted from learned bit fields.
Bundles: header byte(s) + slot bodies, from the verified header/body rules.
Verification: the decoded text is re-assembled with moviAsm and must reproduce the input bytes.
"""
import json, sys, os

OUT = []
T = json.load(open("table.json"))
K = json.load(open("kernel_table.json"))


def gather(word, bits):
    return sum(((word >> b) & 1) << k for k, b in enumerate(bits))


# --- single-op templates -------------------------------------------------------------------
SINGLES = []
ALL = json.load(open("all_templates.json")) if os.path.exists("all_templates.json") else {}
for tpl, e in list(T.items()) + list(K.items()) + list(ALL.items()):
    if "error" in e or "fixed_mask" not in e:
        continue
    if "linear" in e and not e["linear"]:
        continue
    if "toks" in e:
        toks = e["toks"]
    else:
        toks = tpl.split(" ")
    fields = {}
    for k, v in e["fields"].items():
        fields[int(k)] = (v["bits"], v.get("shift") or 0) if isinstance(v, dict) else (v, 0)
    SINGLES.append({"tpl": tpl, "toks": toks, "len": e["len"], "mask": e["fixed_mask"],
                    "val": e["fixed_val"], "fields": fields,
                    "nfix": bin(e["fixed_mask"]).count("1")})
SINGLES.sort(key=lambda s: -s["nfix"])
SINGLE_IDX = {}
for _s in SINGLES:
    _lowfixed = (_s["mask"] & 0xFF) == 0xFF
    SINGLE_IDX.setdefault((_s["len"], (_s["val"] & 0xFF) if _lowfixed else None), []).append(_s)
ALL_BY_OP = {}
for _tpl, _e in ALL.items():
    ALL_BY_OP.setdefault(_tpl.split(" ")[0], []).append((_tpl, _e))


def singles_for(n, word):
    """Templates that can match an n-byte word: same length, low byte equal or unfixed. nfix-desc order."""
    a = SINGLE_IDX.get((n, word & 0xFF), ())
    b = SINGLE_IDX.get((n, None), ())
    return sorted(list(a) + list(b), key=lambda x: -x["nfix"])


def decode_single_word(word, n):
    """word: int of n bytes (little-endian). Returns text or None."""
    for s in singles_for(n, word):
        if s["len"] != n:
            continue
        if word & s["mask"] != s["val"]:
            continue
        toks = list(s["toks"])
        ok = True
        for j, (bits, sh) in s["fields"].items():
            v = gather(word, bits) >> sh
            suf = ""
            if toks[j].startswith("i") and "." in toks[j]:
                suf = "." + toks[j].split(".", 1)[1]
            toks[j] = ("i%d%s" % (v, suf)) if toks[j].startswith("i") else (("v%d" % v) if toks[j].startswith("v") else str(v))
        return " ".join(toks)
    return None


def decode_special_single(data, pos):
    b0 = data[pos]
    if b0 == 0x07:
        return "NOP", 1
    if b0 & 0x0F == 0 and b0 != 0x00 and b0 >> 4 <= 7 and False:
        return None
    if (b0 & 0x0F) == 0 and pos + 1 <= len(data):
        return "NOP %d" % ((b0 >> 4) + 1), 1
    return None


def decode_bru_jmp_or_bra(data, pos):
    if pos + 3 <= len(data) and data[pos] == 0x47 and data[pos + 1] & 0x07 == 0x01 and data[pos + 2] in (0x00, 0x01):
        # register field N: byte1 bits 3..5 = N&7, bits 6..7 = N>>3; byte 2 = 0x01 when a NOP delay follows
        n = ((data[pos + 1] >> 3) & 7) | (((data[pos + 1] >> 6) & 3) << 3)
        return "BRU.JMP i%d" % n, 3
    return None


def _entry(prefix):
    for tpl, e in K.items():
        if tpl.startswith(prefix) and "fixed_mask" in e:
            return tpl, e
    return None, None


def decode_special_word(word, n):
    """LSU0.LDIL / LSU1.LDO.32 / BRU.BRA with measured bit maps (non-linear in the sweep)."""
    t = decode_pccx(word, n)
    if t is not None:
        return t
    if n == 5 and word & 0xFF in (0x82, 0x89) and (word >> 8) & 1:
        # LDIH: same class and immediate map as LDIL, bit 8 set (probed: LSU0.LDIH i0 0 = 82 03 00 00 00)
        unit = "LSU0" if word & 0xFF == 0x82 else "LSU1"
        for tpl, e in ALL_BY_OP.get(unit + ".LDIL", ()):
            m = e.get("fixed_mask", 0) & ~(((1 << 16) - 1) << 18) & ~(1 << 8)
            if (word & m) == (e["fixed_val"] & m):
                dst = gather(word, range(13, 18))
                imm = 0
                for k in range(0, 16):
                    imm |= ((word >> (18 + k)) & 1) << k
                return "%s.LDIH i%d %d" % (unit, dst, imm)
    if n == 3 and word & 0xFF == 0x47 and (word >> 8) & 0x07 == 0x01:
        # register field N (oracle-measured for i0..i31); byte 2 is linker-filled (0x00/0x01/0x22 seen)
        return "BRU.JMP i%d" % (((word >> 11) & 7) | (((word >> 14) & 3) << 3))
    if n == 3 and word & 0xFF == 0x41 and (word >> 8) & 0x1F == 0 and (word >> 16) & 0xFC == 0xA0:
        return "CMU.CMZ.F16 i%d" % (((word >> 13) & 7) | (((word >> 16) & 3) << 3))
    if n == 4 and word & 0xFF == 0xC7:
        off = (word >> 8) & 0xFFFF
        off = off - 0x10000 if off & 0x8000 else off
        return "BRU.BRA %d" % off
    for prefix in ("LSU0.LDIL", "LSU1.LDIL"):
        for tpl, e in ALL_BY_OP.get(prefix, ()):
            m = e.get("fixed_mask", 0) & ~(((1 << 16) - 1) << 18)
            if tpl.startswith(prefix + " ") and "fixed_mask" in e and n == e["len"] and (word & m) == (e["fixed_val"] & m):
                dst = gather(word, e["fields"]["1"]["bits"])
                imm = 0
                for k in range(0, 16):      # value bit k sits at encoding bit 18+k (probed, bit 0 included)
                    imm |= ((word >> (18 + k)) & 1) << k
                return "%s i%d %d" % (prefix, dst, imm)
    for prefix in ("LSU0.STO.32", "LSU1.STO.32"):
        for tpl, e in ALL_BY_OP.get(prefix, ()):
            m = e.get("fixed_mask", 0) & ~(((1 << 11) - 1) << 23)
            if tpl.startswith(prefix + " ") and "fixed_mask" in e and n == e["len"] and (word & m) == (e["fixed_val"] & m):
                dst = gather(word, e["fields"]["1"]["bits"])
                src = gather(word, e["fields"]["2"]["bits"])
                off = 0
                for j in range(0, 10):      # offset stored as offset>>2, bit j at encoding bit 23+j (probed)
                    off |= ((word >> (23 + j)) & 1) << (j + 2)
                return "%s i%d i%d %d" % (prefix, dst, src, off)
    for tpl, e in ALL_BY_OP.get("IAU.SUB", ()):
        m = e.get("fixed_mask", 0) & ~(((1 << 8) - 1) << 23)
        if tpl.startswith("IAU.SUB ") and "fixed_mask" in e and n == e["len"] and (word & m) == (e["fixed_val"] & m):
            dst = gather(word, e["fields"]["1"]["bits"])
            src = gather(word, e["fields"]["2"]["bits"])
            imm = 0
            for k in range(0, 8):           # 7-bit immediate, bit k at encoding bit 23+k (probed)
                imm |= ((word >> (23 + k)) & 1) << k
            return "IAU.SUB i%d i%d %d" % (dst, src, imm)
    for prefix in ("LSU0.LDO.16", "LSU1.LDO.16", "LSU0.STO.16", "LSU1.STO.16"):
        for tpl, e in ALL_BY_OP.get(prefix, ()):
            # offset bits 23..33 are operand bits; the sweep may have missed some of them, so ignore them here
            m = e.get("fixed_mask", 0) & ~(((1 << 12) - 1) << 23)
            if tpl.startswith(prefix + " ") and "fixed_mask" in e and n == e["len"] and (word & m) == (e["fixed_val"] & m):
                dst = gather(word, e["fields"]["1"]["bits"])
                src = gather(word, e["fields"]["2"]["bits"])
                off = 0
                for k in range(1, 13):      # offset in bytes; value bit k at encoding bit 22+k, k<=12 (probed LSU0+LSU1)
                    off |= ((word >> (22 + k)) & 1) << k
                if off & 0x1000:            # negative offsets: 13-bit two's complement
                    off -= 0x2000
                return "%s i%d.0 i%d %d" % (prefix, dst, src, off)
    for prefix, unit in (("LSU0.LDO.32", "LSU0.LDO.32"), ("LSU1.LDO.32", "LSU1.LDO.32")):
        tpl, e = _entry(prefix)
        m = e.get("fixed_mask", 0) & ~(((1 << 11) - 1) << 23) if e else 0
        if tpl and n == e["len"] and (word & m) == (e["fixed_val"] & m):
            dst = gather(word, e["fields"]["1"]["bits"])
            src = gather(word, e["fields"]["2"]["bits"])
            off = 0
            for j in range(0, 10):      # offset is stored as offset>>3, bit j at encoding bit 24+j (probed)
                off |= ((word >> (24 + j)) & 1) << (j + 3)
            off |= ((word >> 23) & 1) << 2   # offset bit 2 (value 4) at encoding bit 23 (probed)
            return "%s i%d i%d %d" % (unit, dst, src, off)
    if n == 4 and word & 0x1FFF == 0x3C and (word >> 23) in SAU_F16_CONST:
        return "SAU.ADD.f16 i%d i%d %s" % (gather(word, range(18, 23)), gather(word, range(13, 18)),
                                          SAU_F16_CONST[word >> 23])
    if n == 4 and word & 0xFF == 0xC6:
        # IAU.ADD reg reg imm7: imm bit k at encoding bit 23+k (same scheme as IAU.SUB)
        for tpl, e in ALL_BY_OP.get("IAU.ADD", ()):
            m = e.get("fixed_mask", 0) & ~(((1 << 8) - 1) << 23)
            if tpl.startswith("IAU.ADD ") and not tpl.split(" ")[3].startswith("i") and "fixed_mask" in e \
                    and (word & m) == (e["fixed_val"] & m):      # immediate forms only (bit 31 = 1)
                dst = gather(word, e["fields"]["1"]["bits"])
                src = gather(word, e["fields"]["2"]["bits"])
                imm = 0
                for k in range(0, 7):
                    imm |= ((word >> (23 + k)) & 1) << k
                return "IAU.ADD i%d i%d %d" % (dst, src, imm)
    return None


SAU_F16_CONST = {224: "0.5", 225: "1.0", 226: "2.0", 241: "-1.0"}   # probed: word>>23 for each constant
PCCX_COND = {0x31: "NEQ", 0x09: "EQ", 0x21: "LT", 0x11: "GT"}      # probed: condition = word bits 8..13


def decode_pccx(word, n):
    # PEU.PCCX cond imm: imm bit i at encoding bit 14+i (probed 0..31)
    if n == 3 and word & 0xFF == 0xC5 and ((word >> 8) & 0x3F) in PCCX_COND:
        return "PEU.PCCX %s %d" % (PCCX_COND[(word >> 8) & 0x3F], (word >> 14) & 0x1F)
    return None


def decode_single(data, pos):
    for n in (1, 2, 3, 4, 5):
        if pos + n <= len(data):
            w = int.from_bytes(data[pos:pos + n], "little")
            t = decode_special_word(w, n)
            if t is not None:
                return t, n
    for n in (1, 2, 3, 4, 5):
        if pos + n > len(data):
            continue
        w = int.from_bytes(data[pos:pos + n], "little")
        t = decode_single_word(w, n)
        if t is not None:
            return t, n
    r = decode_bru_jmp_or_bra(data, pos)
    if r:
        return r
    r = decode_special_single(data, pos)
    if r:
        return r
    return None


# --- bundles: (first class, second class) with header and body widths -----------------------
# Each class: (unit, low byte, length in bytes); body width = 8*len-8 (5-byte LSU ops: 32 bits).
BUNDLES = [
    # header, header bits, slot1 class, slot2 class (slot1 body width, slot2 body width)
    {"hdr": 0x79, "hl": 8, "slots": [("LSU0", 0xC2, 5), ("LSU1", 0x49, 4)]},
    {"hdr": 0x59, "hl": 8, "slots": [("LSU0", 0x42, 4), ("LSU1", 0x49, 4)]},
    {"hdr": 0xB5, "hl": 8, "slots": [("BRU", 0xC7, 4), ("PEU", 0x85, 2)]},
]


def decode_bundle(data, pos):
    for B in BUNDLES:
        hl = B["hl"]
        if pos >= len(data):
            return None
        if data[pos] & ((1 << hl) - 1) != B["hdr"]:
            continue
        bits = int.from_bytes(data[pos:pos + 16], "little")
        off = hl
        parts = []
        total = hl
        for unit, low, n in B["slots"]:
            w = 8 * n - 8
            body = (bits >> off) & ((1 << w) - 1)
            off += w
            word = low | (body << 8)
            parts.append((word, n))
        total = off
        nbytes = (total + 7) // 8
        if pos + nbytes > len(data):
            continue
        texts = []
        for word, n in parts:
            t = decode_special_word(word, n) or decode_single_word(word, n)
            if t is None:
                texts = None
                break
            texts.append(t)
        if texts is None:
            continue
        return " || ".join(texts), nbytes
    return None


def decode(data):
    pos, lines = 0, []
    while pos < len(data):
        r = decode_bundle(data, pos)
        if r is None:
            r = decode_single(data, pos)
        if r is None:
            lines.append(("??", 1))
            pos += 1
            continue
        txt, n = r
        lines.append((txt, n))
        pos += n
    return lines


if __name__ == "__main__":
    data = open(sys.argv[1], "rb").read()
    res = decode(data)
    for txt, n in res:
        print("%2d  %s" % (n, txt))
    print("bytes", sum(n for _, n in res), "of", len(data), "unknown", sum(1 for t, _ in res if t == "??"))
