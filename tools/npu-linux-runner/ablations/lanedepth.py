import re, sys, pathlib
sys.path.insert(0, str(pathlib.Path.home() / "npu-linux-runner"))
import depth as D
ALL = {0, 1, 2, 3}
SW = re.compile(r"NR_V4_SWZ\(\s*([A-Za-z_]\w*)\s*,\s*(\d)\s*,\s*(\d)\s*,\s*(\d)\s*,\s*(\d)\s*\)")
SET = re.compile(r"NR_V4_SET\(\s*([A-Za-z_]\w*)\s*,\s*(\d)\s*,")
lines = open(sys.argv[1]).read().split("\n")
body = D.function_body(lines, sys.argv[2])
stmts = D.statements(D.loop_body(body))
# (var, lane) nodes. Writes: NR_V4_SET writes one lane; plain assignment of a whole vector writes all lanes.
last = {}
depth = []
for i, st in enumerate(stmts):
    reads = set(); writes = set()
    rd_text = st
    for m in SW.finditer(st):
        v = m.group(1)
        for k in range(1, 5):
            reads.add((v, int(m.group(k))))
    rd_text = SW.sub("", rd_text)
    for m in SET.finditer(st):
        writes.add((m.group(1), int(m.group(2))))
    rd_text = SET.sub("", rd_text)
    # whole-vector identifiers in what remains
    m2 = re.search(r"(?<![=!<>])=(?!=)", rd_text)
    if m2:
        lhs = rd_text[:m2.start()]
        rhs = rd_text[m2.end():]
        ids = [x for x in re.findall(r"[A-Za-z_]\w*", lhs) if x not in D.KEYWORDS]
        if ids:
            for l in range(4): writes.add((ids[-1], l))
        rd_text = rhs
    for x in re.findall(r"[A-Za-z_]\w*", rd_text):
        if x in D.KEYWORDS: continue
        for l in range(4): reads.add((x, l))
    d = 1 + max((depth[last[r]] for r in reads if r in last), default=0)
    depth.append(d)
    for w in writes: last[w] = i
crit = max(depth)
print(f"statements {len(stmts)}, lane-level critical path {crit}, ratio {crit/len(stmts):.3f}")
