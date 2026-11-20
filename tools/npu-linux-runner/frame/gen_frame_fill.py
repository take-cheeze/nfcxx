"""Build a synthetic frame batch (fill commands only) for npu-render's frame kernel, and its expected tile.

Writes into <out>:
  frame_fill_entry.c   the frame_core.h renderer, with its local includes inlined, and an entry that calls
                       nr_render_span(data, output) on the blob's tensors (no plane checks, so it runs on the
                       Linux add-model carrier)
  frame_input.npy      the batch as FP16 elements (the blob's data tensor)
  frame_expected.npy   the expected output tile bytes (64-byte output header is checked separately)

usage: gen_frame_fill.py <ptl_kernels dir> <out dir> [seed] [commands]
"""
import pathlib
import re
import struct
import sys

import numpy as np

SPAN = 264192            # NR_FRAME_SPAN: one tensor plane in bytes
HEADER = 128             # NR_FRAME_HEADER_BYTES
COMMAND = 128            # NR_FRAME_COMMAND_BYTES
OUTPUT_PIXELS = 64       # NR_FRAME_OUTPUT_PIXELS
W = H = 128
MAGIC = 0x4E524631       # NR_FRAME_MAGIC

ENTRY = """
/* Entry for the Linux runner: the frame renderer on the blob's data (+0) and output (+80) tensors. */
static nr_u32 nr_param_word(const nr_u8 *p) { return (nr_u32)p[0] | ((nr_u32)p[1] << 8) | ((nr_u32)p[2] << 16) | ((nr_u32)p[3] << 24); }
void nr_probe_kernel(const nr_u8 *params) {
    const nr_u8 *data = (const nr_u8 *)nr_param_word(params);
    nr_u8 *output = (nr_u8 *)nr_param_word(params + 80);
    (void)nr_render_span(data, output);
}
"""


def inline(path, seen=None):
    seen = set() if seen is None else seen
    text = path.read_text()

    def repl(m):
        target = (path.parent / m.group(1)).resolve()
        if target in seen:
            return ""
        seen.add(target)
        return inline(target, seen)

    return re.sub(r'^[ \t]*#include[ \t]+"([^"]+)"[ \t]*$', repl, text, flags=re.M)


def build(seed, commands):
    rng = np.random.default_rng(seed)
    data = bytearray(SPAN)
    cmd_at = HEADER
    prog_at = cmd_at + commands * COMMAND
    vert_at = (prog_at + 4 + 15) & ~15
    atlas_at = vert_at
    bg_at = (atlas_at + 4 + 15) & ~15
    const_at = bg_at + W * H * 4
    assert const_at <= SPAN, const_at
    header = [0] * (HEADER // 4)
    header[0], header[1] = MAGIC, 1
    header[2], header[3] = 0, 0
    header[4], header[5] = W, H
    header[6] = 28                    # format
    header[7] = commands
    header[8] = cmd_at
    header[9] = prog_at
    header[10] = 0                    # program count
    header[11] = vert_at
    header[12] = 0                    # vertex bytes
    header[13] = atlas_at
    header[14] = 4                    # atlas bytes (window count word)
    header[15] = bg_at
    header[16] = const_at
    header[17] = 0                    # constant bytes
    data[0:HEADER] = struct.pack("<32I", *header)
    struct.pack_into("<I", data, prog_at, 0)
    struct.pack_into("<I", data, atlas_at, 0)
    background = rng.integers(0, 256, W * H * 4, dtype=np.uint8)
    data[bg_at : bg_at + W * H * 4] = background.tobytes()
    tile = background.reshape(H, W, 4).copy()
    for k in range(commands):
        x0, y0 = (int(v) for v in rng.integers(0, 120, 2))
        x1, y1 = x0 + int(rng.integers(1, 9)), y0 + int(rng.integers(1, 9))
        color = int(rng.integers(0, 2**32, dtype=np.uint64))
        fields = [0] * (COMMAND // 4)
        fields[0] = 1                      # kind: fill
        fields[1] = 0                      # program
        fields[2] = 0                      # vertex offset
        fields[3] = 0                      # vertex count
        fields[4], fields[5], fields[6], fields[7] = x0, y0, x1, y1
        fields[8] = 0                      # blend mode: over
        fields[9] = 15                     # write mask: all channels
        fields[10] = 0                     # cull
        fields[11] = 0                     # front ccw
        fields[16] = color                 # fill colour (BGRA bytes)
        fields[17] = 0                     # constants offset
        for n in range(4):
            fields[24 + n] = 0xFFFF        # textures: no window
            fields[28 + n] = 0xFFFF
        struct.pack_into(f"<{COMMAND // 4}I", data, cmd_at + k * COMMAND, *fields)
        colour = np.frombuffer(struct.pack("<I", color), dtype=np.uint8)
        tile[y0:y1, x0:x1] = colour
    elements = np.frombuffer(bytes(data), dtype=np.float16)
    return elements, tile.reshape(-1), commands


def main():
    src, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    commands = int(sys.argv[4]) if len(sys.argv) > 4 else 64
    out.mkdir(parents=True, exist_ok=True)
    core = inline(src / "frame_core.h")
    (out / "frame_fill_entry.c").write_text(core + ENTRY)
    elements, tile, n = build(seed, commands)
    np.save(out / "frame_input.npy", elements)
    np.save(out / "frame_expected.npy", tile)
    print(f"wrote {out}: {n} fill commands, {elements.size} FP16 elements, tile {tile.size} bytes")


if __name__ == "__main__":
    main()
