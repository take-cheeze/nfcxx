"""Adds 4-slot bundle headers to tuple_hdr.json (same method as tuple_hdr3.py: oracle-assembled combos,
header = total bits - slot bodies - CMU tail). Existing 2/3-slot entries are kept."""
import itertools, json, re
from learn_list import run_batch, word_of

ORDER = ["VAU", "CMU", "LSU0", "LSU1", "SAU", "IAU", "BRU", "PEU"]
A = json.load(open("all_templates.json"))
cls = {}
for tpl, e in A.items():
    if not e.get("linear") or "fixed_val" not in e:
        continue
    unit = tpl.split(".")[0]
    if unit not in ORDER:
        continue
    key = (unit, e["fixed_val"] & 0xFF, e["len"])
    cls.setdefault(key, {"unit": unit, "text": tpl, "len": e["len"], "low": e["fixed_val"] & 0xFF})
cls.setdefault(("BRU", 0x47, 3), {"unit": "BRU", "text": "BRU.JMP i30", "len": 3, "low": 0x47})
for c in json.load(open("classes.json")):
    if c["unit"] in ORDER:
        key = (c["unit"], c["low"], c["len"])
        cls.setdefault(key, {"unit": c["unit"], "text": c["text"], "len": c["len"], "low": c["low"]})
cls = list(cls.values())


def ren(op, s):
    return re.sub(r"\b([iv])(\d+)", lambda m: m.group(1) + str(int(m.group(2)) + 8 * s), op)


lines, meta = [], []
for combo in itertools.combinations(ORDER, 4):
    pools = [[c for c in cls if c["unit"] == u] for u in combo]
    for choice in itertools.product(*pools):
        lines.append(" || ".join(ren(c["text"], s) for s, c in enumerate(choice)))
        meta.append(choice)
print("4-slot lines:", len(lines), flush=True)

table = json.load(open("tuple_hdr.json"))
res = run_batch(lines, "th4")
fails = 0
for choice, o in zip(meta, res):
    if o[1] != "OK":
        fails += 1
        continue
    X = word_of(o[2])
    total = 8 * len(X)
    bodies, tail = 0, 0
    for c in choice:
        if c["len"] == 5 and c["unit"] == "CMU":
            bodies += 28
            tail += 4
        elif c["len"] == 5 and c["unit"].startswith("LSU") and c["low"] in (0x82, 0x89):
            bodies += 28
        else:
            bodies += 8 * c["len"] - 8
    hl = total - bodies - tail
    if hl < 0 or hl > 32:
        fails += 1
        continue
    xi = int.from_bytes(X, "little")
    hv = xi & ((1 << hl) - 1) if hl else 0
    k = "|".join(c["unit"] + "/" + str(c["len"]) + ":" + format(c["low"], "02x") for c in choice)
    table[k] = [hl, hv, total // 8]
json.dump(table, open("tuple_hdr.json", "w"), indent=0)
print("table:", len(table), "failed:", fails, flush=True)
