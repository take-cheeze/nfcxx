"""Generic NPU 5000 SHAVE decoder: bundles from the measured header table, singles from templates.

Bundle table (tuple_hdr.json): "unit/len:low|..." -> [header bits, header value, total bytes].
Slot body rule: body = word >> 8 (width 8*len-8); a 5-byte CMU in first position uses a 28-bit body and
a 4-bit tail placed after all slot bodies (verified for 2-slot bundles).
"""
import json
import decode_kernel as dk

TB = json.load(open("tuple_hdr.json"))
ENTRIES = []
for k, (hl, hv, nbytes) in TB.items():
    if hl < 8:          # every real bundle carries a header of at least one byte; short ones match anything
        continue
    slots = []
    for part in k.split("|"):
        unit, rest = part.split("/")
        ln, low = rest.split(":")
        slots.append((unit, int(low, 16), int(ln)))
    ENTRIES.append((hl, hv, nbytes, slots))
ENTRIES.sort(key=lambda e: -e[0])


def bits_of(data, start, n):
    v = 0
    for i in range(n):
        p = start + i
        v |= ((data[p >> 3] >> (p & 7)) & 1) << i
    return v


MIN_FIXED = 16


def strict_word(word, n):
    """Decode one slot word only on strong evidence: special forms, or a template whose fixed
    bits are at least MIN_FIXED (weak templates match almost any byte pattern)."""
    t = dk.decode_special_word(word, n)
    if t is not None:
        return t
    best = None
    for s in dk.singles_for(n, word):
        if s["len"] != n or s["nfix"] < MIN_FIXED or word & s["mask"] != s["val"]:
            continue
        if best is None or s["nfix"] > best["nfix"]:
            best = s
    if best is None:
        return None
    toks = list(best["toks"])
    for j, (bits, sh) in best["fields"].items():
        v = dk.gather(word, bits) >> sh
        suf = ""
        if toks[j].startswith("i") and "." in toks[j]:
            suf = "." + toks[j].split(".", 1)[1]
        toks[j] = ("i%d%s" % (v, suf)) if toks[j].startswith("i") else str(v)
    return " ".join(toks)


def class_word(word, n, low):
    """Bundle slot whose class (length, low byte) is fixed by the header: accept the best linear template
    matching the fixed bits, even if it has fewer than MIN_FIXED fixed bits."""
    best = None
    for s in dk.SINGLES:
        if s["len"] != n or (s["mask"] & 0xFF) != 0xFF or (s["val"] & 0xFF) != low:
            continue
        if word & s["mask"] != s["val"]:
            continue
        if best is None or s["nfix"] > best["nfix"]:
            best = s
    if best is None:
        return None
    toks = list(best["toks"])
    for j, (bits, sh) in best["fields"].items():
        v = dk.gather(word, bits) >> sh
        suf = ""
        if toks[j].startswith("i") and "." in toks[j]:
            suf = "." + toks[j].split(".", 1)[1]
        toks[j] = ("i%d%s" % (v, suf)) if toks[j].startswith("i") else str(v)
    return " ".join(toks)


def try_entry(data, pos, hl, hv, nbytes, slots):
    if pos + nbytes > len(data):
        return None
    head = bits_of(data, 8 * pos, hl) if hl else 0
    if head != (hv & ((1 << hl) - 1)):
        return None
    off = 8 * pos + hl
    words = []
    cmu_idx = None
    for i, (unit, low, ln) in enumerate(slots):
        if unit == "CMU" and ln == 5:           # 5-byte CMU: 28-bit body, 4-bit tail after all bodies
            w = 28
            cmu_idx = i
        elif ln == 5 and unit.startswith("LSU") and low in (0x82, 0x89):
            w = 28                              # LDIL: 28-bit body, top nibble always zero
            body = bits_of(data, off, w)
            off += w
            words.append([low | (body << 8), ln, low])
            continue
        else:
            w = 8 * ln - 8
        body = bits_of(data, off, w)
        off += w
        words.append([low | (body << 8), ln, low])
    if cmu_idx is not None:
        nib = bits_of(data, off, 4)
        off += 4
        words[cmu_idx][0] |= nib << 36
    words = [tuple(x) for x in words]
    total_bits = off - 8 * pos
    if (total_bits + 7) // 8 != nbytes:
        return None
    texts = []
    for word, ln, low in words:
        t = strict_word(word, ln) or class_word(word, ln, low)
        if t is None:
            return None
        texts.append(t)
    return " || ".join(texts), nbytes


# The table header length can include padding bits of the last byte, so a bundle may carry a shorter
# header with the same value in its low bits. Index every header length from 8 up to the table value.
BY_HL = {}
for hl, hv, nbytes, slots in ENTRIES:
    for h in range(8, hl + 1):
        BY_HL.setdefault(h, {}).setdefault(hv & ((1 << h) - 1), []).append((h, hv, nbytes, slots))
HL_ORDER = sorted(BY_HL, reverse=True)


def decode_bundle_generic(data, pos):
    for hl in HL_ORDER:
        if 8 * pos + hl > 8 * len(data):
            continue
        head = bits_of(data, 8 * pos, hl)
        for hl_, hv, nbytes, slots in BY_HL[hl].get(head, []):
            r = try_entry(data, pos, hl_, hv, nbytes, slots)
            if r is not None:
                return r
    return None


def decode(data):
    pos, out = 0, []
    while pos < len(data):
        r = decode_bundle_generic(data, pos)
        if r is None:
            r = dk.decode_single(data, pos)
        if r is None:
            out.append(("??", 1))
            pos += 1
            continue
        txt, n = r
        out.append((txt, n))
        pos += n
    return out
