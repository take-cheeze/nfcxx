import pathlib, shutil
root = pathlib.Path.home() / "ablate14"
def make(name, edits):
    d = root / name
    if d.exists(): shutil.rmtree(d)
    d.mkdir(parents=True)
    shutil.copytree(root / "base" / "registered_lab", d / "registered_lab")
    shutil.copytree(root / "base" / "ptl_kernels", d / "ptl_kernels")
    p = d / "ptl_kernels" / "frame_core.h"
    s = p.read_text()
    for old, new in edits:
        assert s.count(old) == 1, (name, old, s.count(old))
        s = s.replace(old, new)
    p.write_text(s)
    print("made", name)
make("inl_sample", [("#define NR_SAMPLE_ATTR NR_NOINLINE", "#define NR_SAMPLE_ATTR NR_INLINE")])
make("inl_helpers", [("#define NR_HELPER_ATTR NR_NOINLINE", "#define NR_HELPER_ATTR NR_INLINE")])
