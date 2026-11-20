"""Fit one template per bundle shape (slot classes) directly from bundle encodings, verify on samples."""
import json, random, re, collections
from learn_list import run_batch, word_of
from fit_fields import fit, REG as REG_TOKEN
REG = re.compile(r"\b([iv])(\d+)((?:\.\d+)?)\b")  # unanchored for substitution

random.seed(21)
C = json.load(open("classes2.json"))
reps = {}
for c in C: reps.setdefault((c["unit"], c["low"], c["len"]), c["text"])
R = list(reps.items())
shapes = []  # list of list-of-rep-texts
for i, (ka, ta) in enumerate(R):
    for kb, tb in R[i + 1:]:
        if ka[0] != kb[0]:
            shapes.append([ta, tb])
T = json.load(open("tuple_hdr_orig.json"))
for k, v in T.items():
    if v[0] < 8:
        texts = []
        ok = True
        for part in k.split("|"):
            u, rest = part.split("/"); ln, low = rest.split(":")
            key = (u, int(low, 16), int(ln))
            if key not in reps: ok = False; break
            texts.append(reps[key])
        if ok and texts not in shapes: shapes.append(texts)
print("bundle shapes:", len(shapes), flush=True)

def vary(t):
    return REG.sub(lambda m: f"{m.group(1)}{random.randrange(32)}{m.group(3)}", t)

N = 40
lines, meta = [], []
for si, texts in enumerate(shapes):
    for _ in range(N):
        b = " || ".join(vary(t) for t in texts)
        lines.append(b); meta.append(si)
out = run_batch(lines, "bfit")
# re-derive operand values per sample from the text we generated (keep them in order)
samples = collections.defaultdict(list)
for line, si, o in zip(lines, meta, out):
    if o[1] != "OK": continue
    w = word_of(o[2])
    if not w: continue
    toks = line.split()
    vals = [int(m.group(1)) for m in re.finditer(r"\b[iv](\d+)", line)]
    samples[si].append((int.from_bytes(w, "little"), vals, len(w)))

results = {}
ok_count = 0
for si, texts in enumerate(shapes):
    S = samples.get(si, [])
    if len(S) < 12: continue
    lens = {x[2] for x in S}
    if len(lens) != 1: continue
    ln = lens.pop()
    # toks: bundle tokens in order, with register tokens recognisable; reuse fit() by building toks
    text = " || ".join(texts)
    toks = []
    for part in texts:
        toks += part.split()
        toks.append("||")
    toks = toks[:-1]
    # fit() reads operand values by register-token order; map vals to register tokens only
    regs = [t for t in toks if REG_TOKEN.match(t)]
    S2 = []
    for e, vals, _ in S:
        if len(vals) != len(regs): break
        full = [0] * (len(toks))
        it = iter(vals)
        for i, t in enumerate(toks):
            if REG_TOKEN.match(t): full[i] = vals[sum(1 for x in toks[:i] if REG_TOKEN.match(x))]
        S2.append((e, full))
    else:
        cols = [i for i, t in enumerate(toks) if REG_TOKEN.match(t)]
        if any(len({x[1][i] for x in S2}) < 2 for i in cols):
            print('no variance', text, flush=True)
            continue
        res = fit(text, ["_"] + toks, ln, S2)
        if isinstance(res, dict):
            ok_count += 1
            results[text] = res
            continue
        print("reject", text, res, flush=True)
print("verified bundle templates:", ok_count, "of", len(shapes), flush=True)
json.dump(results, open("bundle_templates.json", "w"))
print("wrote bundle_templates.json", flush=True)

# Store tokens without the placeholder and shift field keys to match.
fixed = {}
for text, e in results.items():
    e = dict(e)
    assert e["toks"][0] == "_"
    e["toks"] = e["toks"][1:]
    e["fields"] = {str(int(j) - 1): f for j, f in e["fields"].items()}
    fixed[text] = e
json.dump(fixed, open("bundle_templates.json", "w"))
print("stored", len(fixed), "bundle templates", flush=True)
