"""Lower npu-render's nested native-row dispatch to a flat chain.

frame_programs.h dispatches nr_native_row through a nested if-tree. On the NPU build that tree passes the
row argument wrongly when it reaches the deeper row functions (row->immediates reads zero inside nr_row_22,
correct at the entry; see README). A flat chain of `if (native == k) { nr_row_k(row); return; }` gives
correct output for every covered pixel, and the same row functions are called.

usage: flat_dispatch.py <in.c> <out.c>
"""
import re
import sys

HEAD = "NR_NOINLINE void nr_native_row(nr_u32 native, const nr_row *row) {"


def flatten(src):
    rows = sorted({int(m) for m in re.findall(r"NR_NOINLINE void nr_row_(\d+)\(const nr_row \*row\)", src)})
    start = src.index(HEAD)
    end = src.index("\n}\n", start) + 3
    lines = [HEAD, "    if (native >= 38u) native -= 38u;"]
    lines += [f"    if (native == {k}u) {{ nr_row_{k}(row); return; }}" for k in rows]
    lines.append("}\n")
    return src[:start] + "\n".join(lines) + src[end:]


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        text = f.read()
    with open(sys.argv[2], "w") as f:
        f.write(flatten(text))
