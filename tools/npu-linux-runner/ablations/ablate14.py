import pathlib, re, shutil, subprocess, os
R = pathlib.Path.home() / "npu-render-work/src/native/windows"
root = pathlib.Path.home() / "ablate14"
def region(s):
    a = s.index("NR_NOINLINE void nr_row_14(const nr_row *row) {")
    b = s.index("\n}\n", a)
    return a, b
def make(name, fn):
    d = root / name
    if d.exists(): shutil.rmtree(d)
    d.mkdir(parents=True)
    shutil.copytree(R / "registered_lab", d / "registered_lab")
    shutil.copytree(R / "ptl_kernels", d / "ptl_kernels")
    p = d / "ptl_kernels" / "frame_programs.h"
    s = p.read_text()
    a, b = region(s)
    body = fn(s[a:b])
    p.write_text(s[:a] + body + s[b:])
    return d / "ptl_kernels"
variants = {
    "base": lambda b: b,
    "noblend": lambda b: b.replace("nr_blend_pixel(st, pixel, o0)", "(void)0"),
    "noconst": lambda b: re.sub(r"nr_v4_load\(row->constants \+ \d+u\)", "nr_v4_zero()", b),
}
for name, fn in variants.items():
    k = make(name, fn)
    print("made", name, k, flush=True)
