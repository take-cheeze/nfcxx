import pathlib, re, shutil
root = pathlib.Path.home() / "ablate14"
def func_text(s, head):
    a = s.index(head)
    i = s.index("{", a); depth = 0
    for j in range(i, len(s)):
        if s[j] == "{": depth += 1
        elif s[j] == "}":
            depth -= 1
            if depth == 0: return s[a:j+1]
def make(name, copies):
    d = root / name
    if d.exists(): shutil.rmtree(d)
    d.mkdir(parents=True)
    shutil.copytree(root / "base" / "registered_lab", d / "registered_lab")
    shutil.copytree(root / "base" / "ptl_kernels", d / "ptl_kernels")
    core = d / "ptl_kernels" / "frame_core.h"
    fp = d / "ptl_kernels" / "frame_programs.h"
    cs = core.read_text()
    samp = func_text(cs, "NR_SAMPLE_ATTR nr_v4 nr_sample(")
    pads = "\n".join(samp.replace("nr_sample(", f"nr_pad_{k}(") for k in range(copies))
    core.write_text(cs + "\n" + pads + "\n")
    fs = fp.read_text()
    a = fs.index("NR_NOINLINE void nr_row_14(const nr_row *row) {")
    b = fs.index("\n}\n", a)
    calls = "".join(f"    if (row->count < -1000000) {{ nr_v4 pz = nr_pad_{k}(st, 0u, 0u, 0u, row->escapes); (void)pz; }}\n" for k in range(copies))
    protos = "".join(f"NR_SAMPLE_ATTR nr_v4 nr_pad_{k}(const nr_command_state *st, nr_u32 texture, nr_u32 u_bits, nr_u32 v_bits, nr_u32 *escapes);\n" for k in range(copies))
    fs = fs[:a] + protos + fs[a:]
    a = fs.index("NR_NOINLINE void nr_row_14(const nr_row *row) {")
    head_end = fs.index("\n", a)  # after the function signature line
    loop_at = fs.index("    for (px = 0; px < row->count;", a)
    fs = fs[:loop_at] + calls + fs[loop_at:]
    fp.write_text(fs)
    print("made", name, "copies", copies, "pad sample bytes", len(samp))
make("pad8", 8)
make("pad16", 16)
