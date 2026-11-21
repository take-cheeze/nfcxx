"""Lower npu-render's pixel blend with an exact copy-mode fast path.

nr_blend_pixel_alpha computes value = fg*ss + dst*sd, then rounds and packs with the write mask. For blend
mode 0 (source ONE, destination ZERO; see nr_blend_state_load) ss is exactly 255.0 and sd exactly 0.0, so the
destination term adds +0.0 to a finite non-negative product and changes nothing. With all four write-mask
lanes set, the mask select returns the new bytes. The fast path therefore computes the same value and the same
rounding, without loading the destination pixel or running the destination unpack, mask and shift selects.
The general body is kept unchanged after the fast path.

usage: blend_lower.py <in.c> <out.c>
"""
import sys

HEAD = "NR_HELPER_ATTR void nr_blend_pixel_alpha(const nr_command_state *st, nr_u8 *pixel, nr_v4 color, nr_f32 factor_alpha) {\n"

FAST = """    if (st->mode == 0u && NR_UV4_LANE(st->mask_lanes, 0) && NR_UV4_LANE(st->mask_lanes, 1) &&
        NR_UV4_LANE(st->mask_lanes, 2) && NR_UV4_LANE(st->mask_lanes, 3)) {
        /* copy: value = colour * 255 (+ 0 * destination), rounded half-even like the general path */
        nr_v4 fg = nr_v4_clamp01_fast(color), value, fraction;
        nr_uv4 base, up, q, shifted;
        fg = nr_v4_sel(st->swap_mask, NR_V4_SWZ(fg, 2, 1, 0, 3), fg);
        value = nr_v4_mul(fg, nr_v4_splat(255.0f));
        value = nr_v4_sel(nr_v4_gt(value, nr_v4_splat(255.0f)), nr_v4_splat(255.0f), value);
        base = nr_v4_to_u(value); fraction = nr_v4_sub(value, nr_uv4_to_f(base));
        up = nr_uv4_or(nr_v4_gt(fraction, nr_v4_splat(0.5f)), nr_uv4_and(nr_v4_eq(fraction, nr_v4_splat(0.5f)), nr_uv4_eq(nr_uv4_and(base, nr_uv4_splat(1u)), nr_uv4_splat(1u))));
        q = nr_uv4_sub(base, up);
        shifted = nr_uv4_shl(q, st->byte_shifts);
        nr_st(pixel, NR_UV4_LANE(shifted, 0) | NR_UV4_LANE(shifted, 1) | NR_UV4_LANE(shifted, 2) | NR_UV4_LANE(shifted, 3));
        return;
    }
"""


def lower_blend(src):
    if src.count(HEAD) != 1:
        raise SystemExit("nr_blend_pixel_alpha head not unique; the pass does not apply to this source")
    return src.replace(HEAD, HEAD + FAST, 1)


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        text = f.read()
    with open(sys.argv[2], "w") as f:
        f.write(lower_blend(text))
