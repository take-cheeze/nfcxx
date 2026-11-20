"""Lower npu-render's bilinear sampler (nr_sample) with a block fast path.

nr_sample fetches four taps (ix,iy), (jx,iy), (ix,jy), (jx,jy). Each tap runs its own window bounds check
through NR_TAP_PTR. When all four taps fall in the first window, one check on the 2x2 block is enough: the
four addresses are base, base + dx, base + dy and base + dy + dx, the same addresses NR_TAP_PTR computes. The
block path is therefore bit-identical, including escape counts (no tap escapes inside the window). Taps that
leave the first window keep the original per-tap path, in the original order, so escape counts are unchanged.

usage: sampler_lower.py <in.c> <out.c>
"""
import re
import sys

HEAD = "NR_SAMPLE_ATTR nr_v4 nr_sample(const nr_command_state *st, nr_u32 texture, nr_u32 u_bits, nr_u32 v_bits, nr_u32 *escapes) {"

BODY = """NR_SAMPLE_ATTR nr_v4 nr_sample(const nr_command_state *st, nr_u32 texture, nr_u32 u_bits, nr_u32 v_bits, nr_u32 *escapes) {
    nr_f32 tw = (nr_f32)st->texture_w[texture], th = (nr_f32)st->texture_h[texture], half = st->half[texture], lerp = st->lerp[texture];
    nr_f32 u = NR_V4_LANE(nr_v4_clamp01_fast(nr_v4_splat(st->mirror_u[texture] ? nr_mirror01(nr_float(u_bits)) : nr_float(u_bits))), 0) * tw - half;
    nr_f32 v = NR_V4_LANE(nr_v4_clamp01_fast(nr_v4_splat(st->mirror_v[texture] ? nr_mirror01(nr_float(v_bits)) : nr_float(v_bits))), 0) * th - half;
    nr_f32 xmax = tw - 1.0f, ymax = th - 1.0f, x, y, tx, ty;
    nr_u32 ix, iy, jx, jy, ww = st->window_w[texture], wh = st->window_h[texture];
    nr_i32 ox = (nr_i32)st->origin_x[texture], oy = (nr_i32)st->origin_y[texture];
    const nr_u8 *window = st->window_data[texture];
    nr_uv4 shifts = st->byte_shifts, swap = st->swap_mask_texture[texture], ff = nr_uv4_splat(255u);
    nr_v4 t0, t1, t2, t3, top, bottom, one_tx, one_ty, scale = nr_v4_splat(1.0f / 255.0f);
    nr_i32 fx, fy, inside;
    nr_u32 dx, dy;
    const nr_u8 *p0, *p1, *p2, *p3;
    x = u < 0.0f ? 0.0f : u; x = x > xmax ? xmax : x;
    y = v < 0.0f ? 0.0f : v; y = y > ymax ? ymax : y;
    ix = (nr_u32)x; iy = (nr_u32)y;
    jx = ix + ((ix + 1u < st->texture_w[texture]) & (lerp != 0.0f)); jy = iy + ((iy + 1u < st->texture_h[texture]) & (lerp != 0.0f));
    tx = (x - (nr_f32)ix) * lerp; ty = (y - (nr_f32)iy) * lerp;
    fx = (nr_i32)ix - ox; fy = (nr_i32)iy - oy;
    dx = (jx - ix) * 4u; dy = (jy - iy) * ww * 4u;
    inside = fx >= 0 && fy >= 0 && (nr_i32)jx - ox < (nr_i32)ww && (nr_i32)jy - oy < (nr_i32)wh;
#define NR_TAP_PTR(x, y) (((nr_u32)((nr_i32)(x) - ox) < ww && (nr_u32)((nr_i32)(y) - oy) < wh) ? window + ((nr_u32)((nr_i32)(y) - oy) * ww + (nr_u32)((nr_i32)(x) - ox)) * 4 : nr_tap(st, texture, (nr_i32)(x), (nr_i32)(y), escapes))
#define NR_TEXEL(p) nr_v4_mul(nr_uv4_to_f(nr_uv4_and(nr_uv4_shr(nr_uv4_splat(nr_ld(p)), shifts), ff)), scale)
    p0 = inside ? window + ((nr_u32)fy * ww + (nr_u32)fx) * 4u : NR_TAP_PTR(ix, iy);
    t0 = NR_TEXEL(p0);
    /* Point filtering and texel-aligned blits weight the other three taps by zero: one load. */
    if (tx == 0.0f && ty == 0.0f) return nr_v4_sel(swap, NR_V4_SWZ(t0, 2, 1, 0, 3), t0);
    p1 = inside ? p0 + dx : NR_TAP_PTR(jx, iy);
    p2 = inside ? p0 + dy : NR_TAP_PTR(ix, jy);
    p3 = inside ? p0 + dy + dx : NR_TAP_PTR(jx, jy);
    t1 = NR_TEXEL(p1); t2 = NR_TEXEL(p2); t3 = NR_TEXEL(p3);
#undef NR_TAP_PTR
#undef NR_TEXEL
    t0 = nr_v4_sel(swap, NR_V4_SWZ(t0, 2, 1, 0, 3), t0); t1 = nr_v4_sel(swap, NR_V4_SWZ(t1, 2, 1, 0, 3), t1);
    t2 = nr_v4_sel(swap, NR_V4_SWZ(t2, 2, 1, 0, 3), t2); t3 = nr_v4_sel(swap, NR_V4_SWZ(t3, 2, 1, 0, 3), t3);
    one_tx = nr_v4_splat(1.0f - tx); one_ty = nr_v4_splat(1.0f - ty);
    top = nr_v4_add(nr_v4_mul(t0, one_tx), nr_v4_mul(t1, nr_v4_splat(tx)));
    bottom = nr_v4_add(nr_v4_mul(t2, one_tx), nr_v4_mul(t3, nr_v4_splat(tx)));
    return nr_v4_add(nr_v4_mul(top, one_ty), nr_v4_mul(bottom, nr_v4_splat(ty)));
}
"""


def lower_sampler(src):
    if src.count(HEAD) != 1:
        raise SystemExit("nr_sample head not unique; the pass does not apply to this source")
    start = src.index(HEAD)
    end = src.index("\n}\n", start) + 3
    return src[:start] + BODY + src[end:]


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        text = f.read()
    with open(sys.argv[2], "w") as f:
        f.write(lower_sampler(text))
