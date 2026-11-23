import pathlib, re, shutil
R = pathlib.Path.home() / "npu-render-work/src/native/windows"
root = pathlib.Path.home() / "ablate14"
d = root / "hoist"
if d.exists(): shutil.rmtree(d)
d.mkdir(parents=True)
shutil.copytree(R / "registered_lab", d / "registered_lab")
shutil.copytree(R / "ptl_kernels", d / "ptl_kernels")
p = d / "ptl_kernels" / "frame_programs.h"
s = p.read_text()
a = s.index("NR_NOINLINE void nr_row_14(const nr_row *row) {")
b = s.index("\n}\n", a)
body = s[a:b]
offs = sorted({int(x) for x in re.findall(r"nr_v4_load\(row->constants \+ (\d+)u\)", body)})
decl = "".join(f"    const nr_v4 kc_{o} = nr_v4_load(row->constants + {o}u);\n" for o in offs)
body = re.sub(r"nr_v4_load\(row->constants \+ (\d+)u\)", lambda m: f"kc_{m.group(1)}", body)
loop = body.index("    for (px = 0; px < row->count;")
body = body[:loop] + decl + body[loop:]
p.write_text(s[:a] + body + s[b:])
print("hoisted constant loads:", len(offs), "offsets", offs[:12], "...")
