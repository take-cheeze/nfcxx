import pathlib, re, shutil
root = pathlib.Path.home() / "ablate14"
src = root / "hoist" / "ptl_kernels" / "frame_programs.h"
d = root / "hoist2"
if d.exists(): shutil.rmtree(d)
d.mkdir(parents=True)
shutil.copytree(root / "hoist" / "registered_lab", d / "registered_lab")
shutil.copytree(root / "hoist" / "ptl_kernels", d / "ptl_kernels")
p = d / "ptl_kernels" / "frame_programs.h"
s = p.read_text()
a = s.index("NR_NOINLINE void nr_row_14(const nr_row *row) {")
b = s.index("\n}\n", a)
body = s[a:b]
loop = body.index("    for (px = 0; px < row->count;")
head, rest = body[:loop], body[loop:]
ALLOWED = re.compile(r"^(?:kc_\d+|NR_V4_SWZ|nr_v4_neg|nr_v4_abs|\d+|[ ,()])+$")
pat = re.compile(r"nr_v4 (\w+) = ([^;]+);")
hoisted = {}
def repl(m):
    expr = m.group(2).strip()
    if not ALLOWED.match(expr) or "kc_" not in expr:
        return m.group(0)
    if expr not in hoisted:
        hoisted[expr] = f"hv_{len(hoisted)}"
    return f"nr_v4 {m.group(1)} = {hoisted[expr]};"
rest2 = pat.sub(repl, rest)
decl = "".join(f"    const nr_v4 {name} = {expr};\n" for expr, name in hoisted.items())
body2 = head + decl + rest2
p.write_text(s[:a] + body2 + s[b:])
print("distinct invariant expressions:", len(hoisted), "replacements:", sum(1 for _ in re.finditer(r"= hv_\d+;", rest2)))
for e, n in list(hoisted.items())[:5]: print(" ", n, e)
