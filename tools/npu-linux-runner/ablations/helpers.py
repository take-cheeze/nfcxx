import pathlib, shutil
root = pathlib.Path.home() / "ablate14"
def make(name, funcs):
    d = root / name
    if d.exists(): shutil.rmtree(d)
    d.mkdir(parents=True)
    shutil.copytree(root / "base" / "registered_lab", d / "registered_lab")
    shutil.copytree(root / "base" / "ptl_kernels", d / "ptl_kernels")
    p = d / "ptl_kernels" / "frame_core.h"
    s = p.read_text()
    for f in funcs:
        old = f"NR_HELPER_ATTR nr_v4 {f}("
        assert s.count(old) == 1, (f, s.count(old))
        s = s.replace(old, f"NR_INLINE nr_v4 {f}(")
    p.write_text(s)
    print("made", name, funcs, flush=True)
make("inl_small", ["nr_v4_movc", "nr_v4_frc"])
make("inl_cmp", ["nr_v4_cmp_ge"])
