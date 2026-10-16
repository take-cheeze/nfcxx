#!/usr/bin/env python3
# Writes the GPU value check of the memory forms (run by value-check-mem.cu): for each scalar type, one kernel whose body
# is the C++ emitter's own lines for index, load and store (build/pathb-ptx-emit --eval-arith), with the thread's index
# loaded from memory and the value copied out. The runner compares the output with the host's copy of the indexed input.
# Usage: value-check-mem.py OUT.ptx   (needs build/pathb-ptx-emit built)
import os
import subprocess
import sys
import tempfile

here = os.path.dirname(os.path.abspath(__file__))
emit = os.path.join(here, "..", "..", "build", "pathb-ptx-emit")

# type, element size, the register class of a value of the type (its PTX register is %<class>9)
TYPES = [
    ("char", 1, "r"), ("unsigned_char", 1, "r"), ("short", 2, "r"), ("unsigned_short", 2, "r"),
    ("int", 4, "r"), ("unsigned_int", 4, "r"), ("long", 8, "rd"), ("unsigned_long", 8, "rd"),
    ("float", 4, "f"), ("double", 8, "fd"),
]

def emitter_lines(cases):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(cases) + "\n")
        path = f.name
    try:
        out = subprocess.run([emit, "--eval-arith", path], capture_output=True, text=True, check=True).stdout
    finally:
        os.unlink(path)
    return [l for l in out.split("\n")]

def body_for(t, size, cls):
    v = "%" + cls + "9"
    # index: the address of in[idx] (into %rd9); load: the value into v from that address; store: v to out's element.
    index_case = "(mem (ptr) ((%1 %rd1 (ptr)) (%2 %r2 int)) () (index %1 %2 {}))".format(size)
    load_case = "(mem {} ((%1 %rd9 (ptr))) () (load {} %1))".format(t, t)
    store_case = "(stmt ((%1 %rd3 (ptr)) (%2 {} {})) () (store {} %1 %2))".format(v, t, t)
    lines = emitter_lines([index_case, load_case, store_case])
    out = []
    for line, dest in zip(lines[:3], ["%rd9", v, None]):
        if dest is not None:
            line = line.replace("%d", dest)
        out += [x.strip() for x in line.split(" ~ ") if x.strip()]
    return out

def main():
    out_path = sys.argv[1]
    mod = [
        ".version 7.0", ".target sm_75", ".address_size 64", "",
    ]
    for t, size, cls in TYPES:
        name = "k_" + t
        body = body_for(t, size, cls)
        lines = [
            ".visible .entry " + name + "(.param .u64 pin, .param .u64 pidx, .param .u64 pout)", "{",
            "  .reg .pred %p<16>;", "  .reg .b32 %r<16>;", "  .reg .b64 %rd<16>;", "  .reg .f32 %f<16>;",
            "  .reg .f64 %fd<16>;",
            "  ld.param.u64 %rd1, [pin];", "  ld.param.u64 %rd5, [pidx];", "  ld.param.u64 %rd6, [pout];",
            "  mov.u32 %r0, %tid.x;",
            "  mul.wide.u32 %rd7, %r0, 4;", "  add.s64 %rd8, %rd5, %rd7;", "  ld.global.s32 %r2, [%rd8];",
            "  mul.wide.u32 %rd4, %r0, {};".format(size), "  add.s64 %rd3, %rd6, %rd4;",
        ]
        lines += ["  " + b if not b.startswith("  ") else b for b in body]
        lines += ["  ret;", "}", ""]
        mod += lines
    with open(out_path, "w") as f:
        f.write("\n".join(mod) + "\n")

if __name__ == "__main__":
    main()
