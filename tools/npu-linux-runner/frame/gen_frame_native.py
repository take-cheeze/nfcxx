"""Timing batch for any native pixel row (natives 38..75 use the passthrough vertex stage).

The row's usage is read from the emitted source: varyings (row->v[].varying[k]), pixel immediates
(row->immediates + 16*k), pixel constants (row->constants + 16*k) and texture samples (nr_sample(st, t, ...)).
The program record is built with that metadata; its signature is solved (gen_frame_quad.solve_interpolation),
so nr_native_check accepts it. Each draw covers the whole tile. Dummy 128x128 windows back every texture the row
samples. The batch is for timing: pixels are not checked against a reference, only status and coverage.

usage: gen_frame_native.py <ptl_kernels dir> <out dir> <native> [draws] [--vector] [--sampler] [--blend]
"""
import pathlib
import re
import struct
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from gen_frame_fill import ENTRY, HEADER, COMMAND, SPAN, W, H, MAGIC, inline  # noqa: E402
from gen_frame_quad import signature, solve_interpolation  # noqa: E402
from flat_dispatch import flatten  # noqa: E402
from vector_lower import vector_lower  # noqa: E402
from sampler_lower import lower_sampler  # noqa: E402
from blend_lower import lower_blend  # noqa: E402

TEX = 128
WINDOW = 32


def row_body(src, row):
    m = re.search(rf"NR_NOINLINE void nr_row_{row}\(const nr_row \*row\) \{{", src)
    if not m:
        raise SystemExit(f"nr_row_{row} not found")
    i = m.end(); depth = 1
    while depth:
        depth += {"{": 1, "}": -1}.get(src[i], 0); i += 1
    return src[m.start():i]


def usage(body):
    varyings = [int(x) for x in re.findall(r"varying\[(\d+)\]", body)]
    imm = [int(x) for x in re.findall(r"row->immediates \+ (\d+)u", body)]
    cons = [int(x) for x in re.findall(r"row->constants \+ (\d+)u", body)]
    tex = [int(x) for x in re.findall(r"nr_sample\(st, (\d+)u", body)]
    return dict(
        varying_count=(max(varyings) + 1) if varyings else 0,
        ps_immediate_count=(max(imm) // 16 + 1) if imm else 0,
        ps_constants=(max(cons) // 16 + 1) if cons else 0,
        texture_count=(max(tex) + 1) if tex else 0,
    )


def build(src, native, draws, seed):
    row = native - 38
    use = usage(row_body(src, row))
    if use["texture_count"] > 4:
        raise SystemExit("row samples more than four textures")
    rng = np.random.default_rng(seed)
    nvar = use["varying_count"]
    meta = dict(vs_inputs=(1 << (nvar + 1)) - 1, ps_inputs=((1 << nvar) - 1) << 1,
                position_output=0, varying_count=nvar, vs_constants=0, ps_constants=use["ps_constants"],
                texture_count=use["texture_count"], vs_immediate_count=0,
                ps_immediate_count=use["ps_immediate_count"])
    meta["interpolation"] = solve_interpolation(meta, expected_native_signature(src, native))
    assert signature(meta) == expected_native_signature(src, native)

    data = bytearray(SPAN)
    cmd_at = HEADER
    prog_table = cmd_at + draws * COMMAND
    record = (prog_table + 8 + 15) & ~15
    ps_bytes = 64 + meta["ps_immediate_count"] * 16 + meta["ps_constants"] * 16
    vert_at = (record + ps_bytes + 15) & ~15
    stride = nvar + 1                       # vertex inputs: position, then one attribute per varying
    vert_bytes = 6 * stride * 16
    atlas_at = (vert_at + vert_bytes + 15) & ~15
    texels_rel = 4 + WINDOW * max(1, use["texture_count"])
    atlas_bytes = texels_rel + TEX * TEX * 4
    bg_at = (atlas_at + atlas_bytes + 15) & ~15
    const_at = bg_at + W * H * 4
    const_bytes = meta["ps_constants"] * 16
    if const_at + const_bytes > SPAN:
        raise SystemExit("batch does not fit one plane")
    for k in range(meta["ps_constants"]):
        struct.pack_into("<4f", data, const_at + 16 * k, 0.5, 0.5, 0.5, 1.0)

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
    header[17] = const_bytes
    data[0:HEADER] = struct.pack("<32I", *header)
    struct.pack_into("<2I", data, prog_table, 1, record)
    fields = ["native", "vs_inputs", "ps_inputs", "position_output", "interpolation", "varying_count",
              "vs_constants", "ps_constants", "texture_count", "vs_immediate_count", "ps_immediate_count"]
    rec = [native if k == "native" else meta[k] for k in fields]
    struct.pack_into("<16I", data, record, *rec, *([0] * (16 - len(rec))))
    # pixel immediates then pixel constants follow the 64-byte metadata (vertex immediates: none)
    base = record + 64
    for k in range(meta["ps_immediate_count"]):
        struct.pack_into("<4f", data, base + 16 * k, *(0.25 + 0.1 * k, 0.5, 0.75, 1.0))
    # vertices: positions over the tile; attributes 1..nvar and the constant 1.0 for varying 0
    corners = [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)]
    out = []
    for i in [0, 1, 2, 0, 2, 3]:
        x, y = corners[i]
        out.append(struct.pack("<4f", x, y, 0.0, 1.0))
        for a in range(nvar):
            out.append(struct.pack("<4f", 1.0, 1.0, 1.0, 1.0) if a == 0 else struct.pack("<4f", 0.5, 0.5, 0.5, 1.0))
    vb = b"".join(out)
    data[vert_at : vert_at + len(vb)] = vb
    struct.pack_into("<I", data, atlas_at, max(1, use["texture_count"]))
    for t in range(max(1, use["texture_count"])):
        struct.pack_into("<8I", data, atlas_at + 4 + t * WINDOW, texels_rel, TEX, TEX, 0, 0, TEX, TEX, 28)
    texels = rng.integers(0, 256, (TEX, TEX, 4), dtype=np.uint8)
    texels[..., 3] = 255
    data[atlas_at + texels_rel : atlas_at + texels_rel + TEX * TEX * 4] = texels.tobytes()
    data[bg_at : bg_at + W * H * 4] = bytes(W * H * 4)

    for k in range(draws):
        f = [0] * (COMMAND // 4)
        f[3] = 6
        f[4], f[5], f[6], f[7] = 0, 0, W, H
        f[8] = 0
        f[9] = 15
        for n, v in enumerate([0.0, 0.0, float(W), float(H), 0.0, 1.0]):
            f[18 + n] = struct.unpack("<I", struct.pack("<f", v))[0]
        for t in range(4):
            f[24 + t] = t if t < max(1, use["texture_count"]) else 0xFFFF
            f[28 + t] = 0xFFFF
        struct.pack_into(f"<{COMMAND // 4}I", data, cmd_at + k * COMMAND, *f)
    tile = np.zeros((H, W, 4), dtype=np.uint8)
    return np.frombuffer(bytes(data), dtype=np.float16), tile.reshape(-1), draws, use


def expected_native_signature(src, native):
    m = re.search(rf"case {native}u: return p->signature == (0x[0-9a-fA-F]+)u;", src)
    if not m:
        raise SystemExit(f"no native check for {native}")
    return int(m.group(1), 16)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    src_dir, out = pathlib.Path(args[0]), pathlib.Path(args[1])
    native = int(args[2])
    draws = int(args[3]) if len(args) > 3 else 4
    if native < 38 or native > 75:
        raise SystemExit("native must be 38..75 (passthrough vertex stage)")
    src = (src_dir / "frame_programs.h").read_text()
    lowered = flatten(inline(src_dir / "frame_core.h"))
    if "--sampler" in sys.argv:
        lowered = lower_sampler(lowered)
    if "--blend" in sys.argv:
        lowered = lower_blend(lowered)
    if "--vector" in sys.argv:
        lowered = vector_lower(lowered)
    out.mkdir(parents=True, exist_ok=True)
    (out / "frame_fill_entry.c").write_text(lowered + ENTRY)
    elements, tile, n, use = build(src, native, draws, 1)
    np.save(out / "frame_input.npy", elements)
    np.save(out / "frame_expected.npy", tile)
    print(f"native {native} (row {native - 38}): {use}, {n} full-tile draws")


if __name__ == "__main__":
    main()
