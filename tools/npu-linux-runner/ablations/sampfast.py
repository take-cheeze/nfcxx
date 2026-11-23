import pathlib, shutil
root = pathlib.Path.home() / "ablate14"
d = root / "sampfast"
if d.exists(): shutil.rmtree(d)
d.mkdir(parents=True)
shutil.copytree(root / "base" / "registered_lab", d / "registered_lab")
shutil.copytree(root / "base" / "ptl_kernels", d / "ptl_kernels")
p = d / "ptl_kernels" / "frame_core.h"
s = p.read_text()
old = """    t0 = NR_TAP(ix, iy);
    /* Point filtering and texel-aligned blits weight the other three taps by zero: one load. */
    if (tx == 0.0f && ty == 0.0f) return nr_v4_sel(swap, NR_V4_SWZ(t0, 2, 1, 0, 3), t0);
    t1 = NR_TAP(jx, iy); t2 = NR_TAP(ix, jy); t3 = NR_TAP(jx, jy);
#undef NR_TAP
#undef NR_TAP_PTR
"""
new = """    /* All four taps inside the window: one check, then fixed offsets from the first tap. Same loads as NR_TAP. */
#define NR_TAPF(q) nr_v4_mul(nr_uv4_to_f(nr_uv4_and(nr_uv4_shr(nr_uv4_splat(nr_ld(q)), shifts), ff)), scale)
    if ((((nr_u32)((nr_i32)ix - ox) < ww) & ((nr_u32)((nr_i32)jx - ox) < ww) & ((nr_u32)((nr_i32)iy - oy) < wh) & ((nr_u32)((nr_i32)jy - oy) < wh)) != 0u) {
        const nr_u8 *q = window + ((nr_u32)((nr_i32)iy - oy) * ww + (nr_u32)((nr_i32)ix - ox)) * 4u;
        const nr_u32 dxb = (jx - ix) * 4u, dyb = (jy - iy) * ww * 4u;
        t0 = NR_TAPF(q);
        if (tx == 0.0f && ty == 0.0f) return nr_v4_sel(swap, NR_V4_SWZ(t0, 2, 1, 0, 3), t0);
        t1 = NR_TAPF(q + dxb); t2 = NR_TAPF(q + dyb); t3 = NR_TAPF(q + dyb + dxb);
    } else {
        t0 = NR_TAP(ix, iy);
        /* Point filtering and texel-aligned blits weight the other three taps by zero: one load. */
        if (tx == 0.0f && ty == 0.0f) return nr_v4_sel(swap, NR_V4_SWZ(t0, 2, 1, 0, 3), t0);
        t1 = NR_TAP(jx, iy); t2 = NR_TAP(ix, jy); t3 = NR_TAP(jx, jy);
    }
#undef NR_TAPF
#undef NR_TAP
#undef NR_TAP_PTR
"""
assert s.count(old) == 1, s.count(old)
p.write_text(s.replace(old, new))
print("sampfast written")
