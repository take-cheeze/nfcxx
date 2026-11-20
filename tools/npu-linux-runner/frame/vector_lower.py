"""Lower npu-render's four-lane helpers to ext-vector types on the SHAVE build.

frame_core.h selects its nr_v4 representation with `#ifdef __clang__`: clang gets ext_vector_type helpers
that lower to single CMU/VAU operations; other compilers (the SHAVE build is not clang) get structs with
scalar loops. The SHAVE compiler accepts ext vectors (see examples/bench_vector.c), so this pass switches the
two gates that choose the vector branch: the representation itself, and nr_v4_itof.

usage: vector_lower.py <in.c> <out.c>
"""
import sys

REPR = "typedef float nr_v4 __attribute__((ext_vector_type(4)));"
ITOF = "NR_INLINE nr_v4 nr_v4_itof(nr_v4 a) { return nr_iv4_to_f((nr_iv4)a); }"
GATE = "#ifdef __clang__"


def vector_lower(src):
    out = src
    for anchor in (REPR, ITOF):
        if out.count(anchor) != 1:
            raise SystemExit(f"anchor not unique: {anchor[:50]}")
        at = out.index(anchor)
        gate = out.rindex(GATE, 0, at)
        between = out[gate:at]
        if between.count("#else") or between.count("#endif"):
            raise SystemExit("gate is not the nearest enclosing block")
        out = out[:gate] + "#if 1" + out[gate + len(GATE):]
    return out


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        text = f.read()
    with open(sys.argv[2], "w") as f:
        f.write(vector_lower(text))
