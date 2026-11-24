"""Round-trip check: reassemble decoded lines with moviAsm; compare with the original bytes."""
import sys
from decode_generic import decode
from learn_list import run_batch, word_of

data = open(sys.argv[1], "rb").read()
lines = decode(data)
todo = [t for t, _ in lines if t != "??"]
out = iter(run_batch(todo, "rt"))
pos = 0
good = 0
bad = []
for t, n in lines:
    if t == "??":
        bad.append(("unknown", pos, n))
        pos += n
        continue
    o = next(out)
    if o[1] != "OK":
        bad.append(("asm-error", t, (o[3][:80] if len(o) > 3 else "")))
    else:
        b = word_of(o[2])
        if b == data[pos:pos + n]:
            good += 1
        else:
            bad.append(("mismatch", t, data[pos:pos + n].hex(" "), b.hex(" ")))
    pos += n
print("round-trip ok:", good, "items; issues:", len(bad), "of", len(lines))
for x in bad[:20]:
    print(x)
