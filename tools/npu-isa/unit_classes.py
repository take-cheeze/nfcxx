import json, sys
from collections import defaultdict
from learn_list import run_batch, word_of
prefixes = tuple(p + "." for p in sys.argv[1].split(","))
names = sorted(set(l.strip() for l in open("mnemonics.txt") if l.startswith(prefixes)))
shapes = ["{n}", "{n} i1", "{n} i1 i2", "{n} i1 i2 i3", "{n} i1 i2 i3 i4", "{n} i1 1", "{n} i1 i2 1",
          "{n} i1 i2 1.0", "{n} i1 i2 0.5", "{n} i1 i2 i3 1", "{n} i1 0x0800", "{n} i1 i2 i3 i4 i5",
          "{n} i1 2", "{n} i1 i1 i1", "{n} i1 i2 i1", "{n} i1 i1 i2", "{n} i1 i2 i3 i1",
          "{n} v1", "{n} v1 v2", "{n} v1 v2 v3", "{n} v1 i1", "{n} v1 1", "{n} v1 1.0", "{n} i1 v1",
          "{n} v1 v2 i1", "{n} v1 v2 1.0", "{n} i1 v1 v2"]
L = sorted(set(s.format(n=n) for n in names for s in shapes))
out = run_batch(L, "uc")
cls = defaultdict(list)
for l, o in zip(L, out):
    if o[1] != "OK": continue
    b = word_of(o[2]) or b""
    if not b: continue
    cls[(b[0], len(b))].append(l)
tag = sys.argv[1].replace(",", "_"); open("ok_%s.txt" % tag, "w").write(chr(10).join(sorted(l for v in cls.values() for l in v)))
json.dump({"%02x/%d" % k: v[:3] for k, v in cls.items()}, open("cls_%s.json" % tag, "w"), indent=0)
ok_mn = set()
for k, v in cls.items():
    for l in v: ok_mn.add(l.split(" ")[0])
print("mnemonics", len(names), "forms ok", sum(len(v) for v in cls.values()), "mnemonics ok", len(ok_mn))
for k in sorted(cls): print("%02x len %d  n=%d e.g. %s" % (k[0], k[1], len(cls[k]), cls[k][0]))
