"""Lower npu-render's nested native-row dispatch to a flat chain, using the mapping the tree encodes.

frame_programs.h dispatches nr_native_row through a nested if-tree, after `if (native >= 38u) native -= 38u;`.
Natives 13 and up do not map to row 13 and up: the tree sends native 13 to nr_row_10, native 14 to nr_row_13, and
so on (see flat_vertex.tree_leaves). The NPU build also passes the row argument wrongly when it reaches the deeper
rows (row->immediates reads zero inside nr_row_22 but is correct at entry). This pass evaluates the tree for each
native id and emits a flat chain `if (native == n) { nr_row_J(row); return; }`, with the same mapping as the tree.

usage: flat_dispatch.py <in.c> <out.c>
"""
import re
import sys

from flat_vertex import tree_leaves, holds

HEAD = "NR_NOINLINE void nr_native_row(nr_u32 native, const nr_row *row) {"
ROW_CALL = re.compile(r"(nr_row_\w+)\(row\);")


def flatten(src, count=76):
    start = src.index(HEAD)
    end = src.index("\n}\n", start) + 3
    body = src[start:end]
    # the tree is written for native < 38; natives 38.. reach it after `native -= 38u`
    import flat_vertex
    previous = flat_vertex.LEAF
    flat_vertex.LEAF = ROW_CALL
    try:
        leaves = tree_leaves(body)
    finally:
        flat_vertex.LEAF = previous
    lines = [HEAD, "    if (native >= 38u) native -= 38u;"]
    # after the reduction native is 0..37; natives 38.. arrive here as 0..37 too
    for k in range(38):
        hits = [callee for path, callee in leaves if holds(path, k)]
        if len(hits) != 1:
            raise SystemExit(f"row {k}: {len(hits)} leaves match")
        lines.append(f"    if (native == {k}u) {{ {hits[0]}(row); return; }}")
    lines.append("}\n")
    return src[:start] + "\n".join(lines) + src[end:]


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        text = f.read()
    with open(sys.argv[2], "w") as f:
        f.write(flatten(text))
