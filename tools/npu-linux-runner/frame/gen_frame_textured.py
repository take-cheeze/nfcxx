"""Build a frame batch whose draws sample a 128x128 texture through npu-render's shader path.

The program is native 39 = 38 + 1: passthrough vertex stage and row 1, which samples texture 0 at the uv
carried in varying 1; row 1 multiplies the sample by varying 0, which is 1.0. Vertex attributes are position, a constant 1.0, and uv, so
ps_inputs selects outputs 1 and 2 as the two varyings. The program signature is solved from the
interpolation field to match nr_native_check for native 39.

The texture is 128x128 opaque RGBA in an atlas window. The quad maps uv (pixel centre)/128, so each covered
pixel should return the texel at its own position. Commands use blend mode 0 (copy).

usage: gen_frame_textured.py <ptl_kernels dir> <out dir> [seed] [draws]
"""
import pathlib
import re
import struct
import sys

import numpy as np

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from gen_frame_fill import ENTRY, HEADER, COMMAND, SPAN, W, H, MAGIC  # noqa: E402
from gen_frame_quad import signature, solve_interpolation  # noqa: E402
from gen_frame_fill import inline  # noqa: E402
from flat_dispatch import flatten  # noqa: E402

NATIVE = 39
TEX = 128
WINDOW = 32      # NR_FRAME_WINDOW_BYTES
STRIDE = 3       # attributes per vertex: position, uv, uv


def expected_signature(src):
    m = re.search(rf"case {NATIVE}u: return p->signature == (0x[0-9a-fA-F]+)u;", src)
    if not m:
        raise SystemExit(f"no native check for {NATIVE}")
    return int(m.group(1), 16)


def vertices():
    # corners in clip space, with the uv of the texel corner that lands on each (y grows down the tile)
    corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]
    uvs = [(0.0, 1.0), (1.0, 1.0), (1.0, 0.0), (0.0, 0.0)]
    out = []
    for i in [0, 1, 2, 0, 2, 3]:
        x, y = corners[i]
        u, v = uvs[i]
        out.append(struct.pack("<4f", x, y, 0.0, 1.0))
        out.append(struct.pack("<4f", 1.0, 1.0, 1.0, 1.0))   # varying 0: row 1 multiplies the sample by it
        out.append(struct.pack("<4f", u, v, 0.0, 0.0))       # varying 1: sampling coordinates
    return b"".join(out)


def build(src, seed, draws):
    rng = np.random.default_rng(seed)
    data = bytearray(SPAN)
    meta = dict(vs_inputs=0b111, ps_inputs=0b110, position_output=0, varying_count=2,
                vs_constants=0, ps_constants=0, texture_count=1, vs_immediate_count=0, ps_immediate_count=0)
    meta["interpolation"] = solve_interpolation(meta, expected_signature(src))
    assert signature(meta) == expected_signature(src)

    cmd_at = HEADER
    prog_table = cmd_at + draws * COMMAND
    record = (prog_table + 8 + 15) & ~15
    vert_at = (record + 64 + 15) & ~15
    vert_bytes = 6 * STRIDE * 16
    atlas_at = (vert_at + vert_bytes + 15) & ~15
    texels_rel = 4 + WINDOW                              # texels follow the count word and one record
    texels_bytes = TEX * TEX * 4
    atlas_bytes = texels_rel + texels_bytes
    bg_at = (atlas_at + atlas_bytes + 15) & ~15
    const_at = bg_at + W * H * 4
    assert const_at <= SPAN, const_at

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
    header[14] = atlas_bytes
    header[15] = bg_at
    header[16] = const_at
    header[17] = 0
    data[0:HEADER] = struct.pack("<32I", *header)
    struct.pack_into("<2I", data, prog_table, 1, record)

    rec = [0] * 16
    for i, key in enumerate(["native", "vs_inputs", "ps_inputs", "position_output", "interpolation",
                             "varying_count", "vs_constants", "ps_constants", "texture_count",
                             "vs_immediate_count", "ps_immediate_count"]):
        rec[i] = NATIVE if key == "native" else meta[key]
    struct.pack_into("<16I", data, record, *rec)

    data[vert_at : vert_at + vert_bytes] = vertices()

    # atlas: window count, one window record (offset of texels relative to the atlas, size, origin, format)
    struct.pack_into("<I", data, atlas_at, 1)
    struct.pack_into("<8I", data, atlas_at + 4, texels_rel, TEX, TEX, 0, 0, TEX, TEX, 28)
    texels = rng.integers(0, 256, (TEX, TEX, 4), dtype=np.uint8)
    texels[..., 3] = 255                                  # opaque
    data[atlas_at + texels_rel : atlas_at + texels_rel + texels_bytes] = texels.tobytes()

    bg = rng.integers(0, 256, W * H * 4, dtype=np.uint8)
    data[bg_at : bg_at + W * H * 4] = bg.tobytes()
    tile = bg.reshape(H, W, 4).copy()

    for k in range(draws):
        x0, y0 = (int(v) for v in rng.integers(0, 120, 2))
        x1, y1 = x0 + int(rng.integers(1, 9)), y0 + int(rng.integers(1, 9))
        f = [0] * (COMMAND // 4)
        f[0] = 0                  # draw
        f[1] = 0                  # program index
        f[2] = 0                  # vertex offset
        f[3] = 6                  # vertex count
        f[4], f[5], f[6], f[7] = x0, y0, x1, y1
        f[8] = 0                  # blend: copy (source ONE, destination ZERO)
        f[9] = 15
        for n, v in enumerate([0.0, 0.0, float(W), float(H), 0.0, 1.0]):
            f[18 + n] = struct.unpack("<I", struct.pack("<f", v))[0]
        f[24] = 0                 # texture 0 is window 0
        for n in range(1, 4):
            f[24 + n] = 0xFFFF
        for n in range(4):
            f[28 + n] = 0xFFFF
        struct.pack_into(f"<{COMMAND // 4}I", data, cmd_at + k * COMMAND, *f)
        # the tile holds the texel at each pixel position (uv = pixel centre / 128)
        tile[y0:y1, x0:x1] = texels[y0:y1, x0:x1]
    return np.frombuffer(bytes(data), dtype=np.float16), tile.reshape(-1), draws


def main():
    src_dir, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    draws = int(sys.argv[4]) if len(sys.argv) > 4 else 16
    out.mkdir(parents=True, exist_ok=True)
    src = (src_dir / "frame_programs.h").read_text()
    core = inline(src_dir / "frame_core.h")
    (out / "frame_fill_entry.c").write_text(flatten(core) + ENTRY)
    elements, tile, n = build(src, seed, draws)
    np.save(out / "frame_input.npy", elements)
    np.save(out / "frame_expected.npy", tile)
    print(f"wrote {out}: {n} textured draws, {elements.size} FP16 elements")


if __name__ == "__main__":
    main()
