"""Refit register-operand fields of npu-isa templates from assembler samples.

For every template whose operands are register-like (iN / vN, optional .N suffix), sample random register
numbers, assemble them with the MoviTools oracle, and fit:
  * a field per operand: the encoding bit that tracks each of the operand's 5 value bits;
  * a literal token for an operand no encoding bit tracks (the assembler accepts but ignores it);
  * fixed_mask/fixed_val for the constant bits.
A template is replaced only if the fit reconstructs every accepted sample exactly.

Usage: fit_fields.py <in.json> <out.json> [samples_per_template]
"""
import json
import random
import re
import sys
from collections import Counter

from learn_list import run_batch, word_of

REG = re.compile(r"^([iv])(\d+)((?:\.\d+)?)$")


def fit(key, toks, ln, S):
    """S: list of (encoding_int, [reg values per operand index]). Returns template dict or a reason string."""
    nbits = 8 * ln
    fields, literal, used = {}, set(), set()
    for i, tok in enumerate(toks[1:]):
        if not REG.match(tok):
            continue  # immediates and other literals are constant in every sample
        bits = []
        for j in range(5):
            cands = [p for p in range(nbits) if p not in used and
                     all(((e >> p) & 1) == ((v[i] >> j) & 1) for e, v in S)]
            if not cands:
                if j == 0:
                    literal.add(i + 1)  # no bit tracks this operand: the encoder ignores it
                    break
                return "partial-field"
            bits.append(cands[0])  # equal-valued duplicates are interchangeable; take the first
        if i + 1 in literal:
            continue
        used.update(bits)
        fields[str(i + 1)] = {"bits": bits, "shift": 0}
    fmask = fval = 0
    for p in range(nbits):
        if p in used:
            continue
        vs = {(e >> p) & 1 for e, _ in S}
        if len(vs) != 1:
            return "nonconst-bit"
        fmask |= 1 << p
        fval |= vs.pop() << p

    def rebuild(vals):
        e = fval
        for fk, f in fields.items():
            for j, p in enumerate(f["bits"]):
                e |= ((vals[int(fk) - 1] >> j) & 1) << p
        return e

    if any(rebuild(v) != e for e, v in S):
        return "verify"
    return {"len": ln, "fixed_mask": fmask, "fixed_val": fval, "fields": fields, "toks": toks,
            "linear": True}


def main():
    src, dst = sys.argv[1], sys.argv[2]
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 40
    A = json.load(open(src))
    random.seed(7)
    targets = []
    for key, t in A.items():
        toks = t.get("toks") or key.split()
        ops = toks[1:]
        if not ops or t.get("len") is None or t.get("fixed_mask") is None:
            continue
        if not any(REG.match(o) for o in ops):
            continue
        targets.append((key, toks, t["len"]))
    print("templates with register operands:", len(targets), flush=True)

    lines, meta = [], []
    for key, toks, ln in targets:
        for _ in range(n):
            vals = [random.randrange(32) for _ in toks[1:]]
            parts = [toks[0]]
            for tok, v in zip(toks[1:], vals):
                m = REG.match(tok)
                parts.append(f"{m.group(1)}{v}{m.group(3)}" if m else tok)
            lines.append(" ".join(parts))
            meta.append((key, ln, vals))
    print("assembling", len(lines), flush=True)
    out = run_batch(lines, "fitfields")

    samples = {}
    for (key, ln, vals), o in zip(meta, out):
        if o[1] != "OK":
            continue
        w = word_of(o[2])
        if w is None or len(w) != ln:
            continue
        samples.setdefault(key, []).append((int.from_bytes(w, "little"), vals))

    reasons = Counter()
    refit = 0
    for key, toks, ln in targets:
        S = samples.get(key, [])
        if len(S) < 12:
            reasons["few-samples"] += 1
            continue
        res = fit(key, toks, ln, S)
        if isinstance(res, str):
            reasons[res] += 1
            continue
        A[key] = res
        refit += 1
    print("refit:", refit, "kept original:", sum(reasons.values()), dict(reasons), flush=True)
    json.dump(A, open(dst, "w"))
    print("wrote", dst, flush=True)


if __name__ == "__main__":
    main()
