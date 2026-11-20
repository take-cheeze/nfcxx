"""Build a frame batch whose commands draw a solid-colour quad through npu-render's shader path.

The program is native 60 = 38 + 22: the passthrough vertex stage and the NPU row 22, which writes
immediate 0 as its colour and uses no texture sample (frame_programs.h, nr_row_22). Its record is built to pass nr_program_load: the signature is a
hash of the metadata (frame_core.h nr_program_signature), so the interpolation field is solved for the
signature that nr_native_check expects for native 60.

Each draw covers a random clip rectangle with a full-tile quad (two triangles). The expected tile is the
colour quantised to bytes, written into each clip rectangle in command order.

usage: gen_frame_quad.py <ptl_kernels dir> <out dir> [seed] [draws] [--direct-row22]
"""
import pathlib
import re
import struct
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gen_frame_fill import ENTRY, HEADER, COMMAND, SPAN, W, H, MAGIC, inline  # noqa: E402

NATIVE = 60                       # 38 + 22: passthrough vertex stage, row 22 (immediate colour, no sample)
SIG_MASK = 0xFFFFFFFF
K_A, K_B, K_I = 0x9E3779B1, 0x85EBCA77, 0xC2B2AE3D


def signature(v):
    a = (v["vs_inputs"] | (v["ps_inputs"] << 16) | (v["position_output"] << 24) | (v["varying_count"] << 28)) & SIG_MASK
    b = (v["vs_constants"] | (v["ps_constants"] << 9) | (v["texture_count"] << 18)
         | (v["vs_immediate_count"] << 21) | (v["ps_immediate_count"] << 27)) & SIG_MASK
    return ((a * K_A) & SIG_MASK) ^ ((b * K_B) & SIG_MASK) ^ ((v["interpolation"] * K_I) & SIG_MASK)


def expected_signature(src):
    """The signature nr_native_check requires for NATIVE, read from the generated source."""
    m = re.search(rf"case {NATIVE}u: return p->signature == (0x[0-9a-fA-F]+)u;", src)
    if not m:
        raise SystemExit(f"no native check for {NATIVE}")
    return int(m.group(1), 16)


def solve_interpolation(meta, want):
    """signature is linear in interpolation through an odd multiplier, so one value hits `want` exactly."""
    base = signature(dict(meta, interpolation=0))
    need = (want ^ base) & SIG_MASK
    inv = pow(K_I, -1, 1 << 32)
    return (need * inv) & SIG_MASK


def quad_vertices():
    # clip-space positions (x, y, z, w) of a full-tile quad as two triangles
    corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]
    order = [0, 1, 2, 0, 2, 3]
    out = []
    for i in order:
        x, y = corners[i]
        out.append(struct.pack("<4f", x, y, 0.0, 1.0))
    return b"".join(out)


def build(src, seed, draws):
    rng = np.random.default_rng(seed)
    data = bytearray(SPAN)
    meta = dict(vs_inputs=1, ps_inputs=0, position_output=0, varying_count=0, vs_constants=0, ps_constants=0,
                texture_count=0, vs_immediate_count=0, ps_immediate_count=1)
    meta["interpolation"] = solve_interpolation(meta, expected_signature(src))
    assert signature(meta) == expected_signature(src)

    cmd_at = HEADER
    prog_table = cmd_at + draws * COMMAND
    record = (prog_table + 8 + 15) & ~15          # 16-byte aligned program record
    record_bytes = 64 + 16                        # metadata + one vec4 immediate
    vert_at = (record + record_bytes + 15) & ~15
    vert_bytes = 6 * 16
    atlas_at = (vert_at + vert_bytes + 15) & ~15
    bg_at = (atlas_at + 4 + 15) & ~15
    const_at = bg_at + W * H * 4
    assert const_at <= SPAN

    header = [0] * 32
    header[0], header[1] = MAGIC, 1
    header[4], header[5] = W, H
    header[6] = 28
    header[7] = draws
    header[8] = cmd_at
    header[9] = prog_table
    header[10] = 1
    header[11] = vert_at
    header[12] = vert_bytes
    header[13] = atlas_at
    header[14] = 4
    header[15] = bg_at
    header[16] = const_at
    header[17] = 0
    data[0:HEADER] = struct.pack("<32I", *header)
    struct.pack_into("<2I", data, prog_table, 1, record)

    fields = dict(native=NATIVE, vs_inputs=meta["vs_inputs"], ps_inputs=meta["ps_inputs"],
                  position_output=meta["position_output"], interpolation=meta["interpolation"],
                  varying_count=meta["varying_count"], vs_constants=meta["vs_constants"],
                  ps_constants=meta["ps_constants"], texture_count=meta["texture_count"],
                  vs_immediate_count=meta["vs_immediate_count"], ps_immediate_count=meta["ps_immediate_count"])
    rec = [0] * 16
    for i, key in enumerate(["native", "vs_inputs", "ps_inputs", "position_output", "interpolation",
                             "varying_count", "vs_constants", "ps_constants", "texture_count",
                             "vs_immediate_count", "ps_immediate_count"]):
        rec[i] = fields[key]
    struct.pack_into("<16I", data, record, *rec)

    color = rng.uniform(0.0, 1.0, 4).astype(np.float32)
    color[3] = 1.0                                  # opaque: 'over' replaces the destination
    struct.pack_into("<4f", data, record + 64, *color)
    data[vert_at : vert_at + vert_bytes] = quad_vertices()
    data[bg_at : bg_at + W * H * 4] = rng.integers(0, 256, W * H * 4, dtype=np.uint8).tobytes()
    tile = np.frombuffer(bytes(data[bg_at : bg_at + W * H * 4]), dtype=np.uint8).reshape(H, W, 4).copy()

    byte_color = np.clip(np.rint(color * 255.0), 0, 255).astype(np.uint8)
    for k in range(draws):
        x0, y0 = (int(v) for v in rng.integers(0, 120, 2))
        x1, y1 = x0 + int(rng.integers(1, 9)), y0 + int(rng.integers(1, 9))
        f = [0] * (COMMAND // 4)
        f[0] = 0                          # kind: draw
        f[1] = 0                          # program index
        f[2] = 0                          # vertex offset
        f[3] = 6                          # vertex count
        f[4], f[5], f[6], f[7] = x0, y0, x1, y1
        f[8] = 0                          # blend: over
        f[9] = 15                         # write mask
        f[10] = 0                         # cull
        f[11] = 0                         # front ccw
        # viewport (words 18..21) and depth (words 22..23) are floats; full tile, depth 0..1
        for n, v in enumerate([0.0, 0.0, float(W), float(H), 0.0, 1.0]):
            f[18 + n] = struct.unpack("<I", struct.pack("<f", v))[0]
        for n in range(4):
            f[24 + n] = 0xFFFF            # textures: no window
            f[28 + n] = 0xFFFF
        struct.pack_into(f"<{COMMAND // 4}I", data, cmd_at + k * COMMAND, *f)
        tile[y0:y1, x0:x1] = byte_color
    elements = np.frombuffer(bytes(data), dtype=np.float16)
    return elements, tile.reshape(-1), draws, color


# On the NPU build, nr_native_row loses its row argument when it reaches nr_row_22 through the nested
# dispatch tree: row->immediates reads zero inside nr_row_22 but is correct at nr_native_row's entry.
# Calling nr_row_22 directly gives the correct colour for every covered pixel (see README).
DISPATCH_SHORTCUT = "    if (native == 22u) { nr_row_22(row); return; }\n"
DISPATCH_HEAD = "NR_NOINLINE void nr_native_row(nr_u32 native, const nr_row *row) {\n    if (native >= 38u) native -= 38u;\n"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    direct_row22 = "--direct-row22" in sys.argv
    src_dir, out = pathlib.Path(args[0]), pathlib.Path(args[1])
    seed = int(args[2]) if len(args) > 2 else 1
    draws = int(args[3]) if len(args) > 3 else 16
    out.mkdir(parents=True, exist_ok=True)
    src = (src_dir / "frame_programs.h").read_text()
    core = inline(src_dir / "frame_core.h")
    if direct_row22:
        if core.count(DISPATCH_HEAD) != 1:
            raise SystemExit("nr_native_row head not found; the workaround does not apply to this source")
        core = core.replace(DISPATCH_HEAD, DISPATCH_HEAD + DISPATCH_SHORTCUT)
    (out / "frame_fill_entry.c").write_text(core + ENTRY)
    elements, tile, n, color = build(src, seed, draws)
    np.save(out / "frame_input.npy", elements)
    np.save(out / "frame_expected.npy", tile)
    print(f"wrote {out}: {n} quad draws, colour {np.round(color, 3)}, {elements.size} FP16 elements")


if __name__ == "__main__":
    main()
