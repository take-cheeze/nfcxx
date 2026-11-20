#!/usr/bin/env python3
"""MLIR (compiler-adapted LLVM dialect) -> typed-pointer LLVM IR for moviCompile (LLVM 14).

Stages:
  1. keep only the llvm.func definitions of the SW module (as the compiler's translateToLLVMIR does)
  2. normalise the printed syntax for the installed mlir-translate (LLVM 20)
  3. mlir-translate --mlir-to-llvmir  (opaque pointers)
  4. rewrite opaque `ptr` to `i8*`, with bitcasts around every load/store/GEP so the
     pointee type is explicit, which LLVM 14 requires; lower llvm.maximum and strip
     LLVM 20 attribute groups that LLVM 14 cannot parse.
  5. (abi=act, default) replace the compiler's flat-record entry with a shim that follows the
     ACT tensor-record ABI: operand k (inputs first, output last) has its address at
     record+0x28*k; the output is therefore at record+0x28*N for N inputs.
Usage: mlir2typed.py <adapted.mlir> <out.ll> [act|flat]
"""
import os, re, subprocess, sys, tempfile

MLIR_TRANSLATE = "mlir-translate-20"
LIBDIR = "/usr/lib/llvm-20/lib"
TY = r"(?:[iI]\d+|half|float|double|ptr)"
NAME = r"[%@\w.]+"
RECORD_BYTES = 0x28


def kernel_only(src):
    out, inside = [], False
    for l in src.split("\n"):
        if not inside and re.match(r"\s*llvm\.func (internal )?@", l):
            inside = True
        if inside:
            out.append(l)
            if l.startswith("    }"):
                inside = False
                out.append("")
    body = "\n".join(out)
    body = body.replace("inbounds|nuw", "inbounds").replace("inbounds|nsw", "inbounds")
    body = re.sub(r"\b(nuw|nsw) ", "", body)
    return "module {\n" + body + "\n}\n"


def translate(mlir_text):
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "k.mlir")
        with open(p, "w") as fh:
            fh.write(mlir_text)
        env = dict(os.environ, LD_LIBRARY_PATH=LIBDIR)
        r = subprocess.run([MLIR_TRANSLATE, "--mlir-to-llvmir", p], env=env, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("mlir-translate failed:\n" + r.stderr[:2000])
        return r.stdout


def typed(ll):
    out, n = [], [0]

    def tmp():
        n[0] += 1
        return "%%tc%d" % n[0]

    load_re = re.compile(r"(\s*)(%%[\w.]+) = load (?:volatile )?(%s), ptr (%s)(.*)$" % (TY, NAME))
    store_re = re.compile(r"(\s*)store (?:volatile )?(%s) ([^,]+), ptr (%s)(.*)$" % (TY, NAME))
    gep_re = re.compile(r"(\s*)(%%[\w.]+) = getelementptr (inbounds )?(%s), ptr (%s)(.*)$" % (TY, NAME))
    for line in ll.split("\n"):
        ind = re.match(r"\s*", line).group(0)
        m = load_re.match(line)
        if m:
            ty = "i8*" if m.group(3) == "ptr" else m.group(3)
            pc = tmp()
            out.append("%s%s = bitcast i8* %s to %s*" % (ind, pc, m.group(4), ty))
            out.append("%s%s = load %s, %s* %s%s" % (ind, m.group(2), ty, ty, pc, m.group(5)))
            continue
        m = store_re.match(line)
        if m:
            vt = "i8*" if m.group(2) == "ptr" else m.group(2)
            pc = tmp()
            out.append("%s%s = bitcast i8* %s to %s*" % (ind, pc, m.group(4), vt))
            out.append("%sstore %s %s, %s* %s%s" % (ind, vt, m.group(3), vt, pc, m.group(5)))
            continue
        m = gep_re.match(line)
        if m:
            ty = "i8*" if m.group(4) == "ptr" else m.group(4)
            pc, gt = tmp(), tmp()
            ib = "inbounds " if m.group(3) else ""
            out.append("%s%s = bitcast i8* %s to %s*" % (ind, pc, m.group(5), ty))
            out.append("%s%s = getelementptr %s%s, %s* %s%s" % (ind, gt, ib, ty, ty, pc, m.group(6)))
            out.append("%s%s = bitcast %s* %s to i8*" % (ind, m.group(2), ty, gt))
            continue
        out.append(line)
    text = "\n".join(out)
    # remaining pointer types (arguments, phi, select, call, inttoptr results) become i8*
    return re.sub(r"(?<![%@\w.])ptr\b", "i8*", text)


def legacy_attrs(ll):
    """LLVM 14 (moviCompile) can't parse LLVM 20 attribute groups, and it lacks the
    llvm.maximum intrinsic. Drop the attribute groups and lower maximum to compare+select
    (NaN-propagation of llvm.maximum is not preserved)."""
    ll = re.sub(r"^attributes #\d+ = \{.*\}\n?", "", ll, flags=re.M)
    ll = re.sub(r" #\d+( \{)", r"\1", ll)
    ll = re.sub(r"^; Function Attrs:.*\n", "", ll, flags=re.M)
    ll = re.sub(r"^declare (\S+) @llvm\.maximum\.\w+\(.*\n", "", ll, flags=re.M)
    count = [0]

    def lower(m):
        dst, ty, a, b = m.group(1), m.group(2), m.group(3), m.group(4)
        count[0] += 1
        cond = "%%mx%d.c" % count[0]
        return "%s = fcmp ogt %s %s, %s\n  %s = select i1 %s, %s %s, %s %s" % (
            cond, ty, a, b, dst, cond, ty, a, ty, b)

    return re.sub(r"(%[\w.]+) = call (half|float|double) @llvm\.maximum\.\w+\(\2 (%[\w.]+|0x\w+), \2 (%[\w.]+|0x\w+)\)",
                  lower, ll)


def act_shim(ll):
    """Replace the compiler's flat-record entry (generated_0) with a shim that follows the ACT
    tensor-record ABI. The implementation takes, per memref operand, (base, aligned, offset,
    sizes..., strides...). Operands are ordered inputs then output, and operand k's address is
    at record+0x28*k. For static shapes only the base pointers are read, so each address feeds
    both the base and aligned slots; scalar fields are passed as zero."""
    m = re.search(r"define (?:internal )?(.+?) @__impl_generated_0\((.*?)\)", ll)
    if not m:
        sys.exit("implementation __impl_generated_0 not found")
    ret, params = m.group(1), m.group(2)
    ptypes = [p.strip().split(" ")[0] for p in params.split(", ")]
    n_ptr = sum(1 for t in ptypes if t == "i8*")
    if n_ptr % 2 or n_ptr == 0:
        sys.exit("expected (base, aligned) pointer pairs per memref operand, found %d pointers" % n_ptr)
    n_ops = n_ptr // 2
    # drop the flat-record entry (a top-level define of generated_0 up to its closing brace)
    ll = re.sub(r"define [^\n]*@generated_0\(.*?\n}\n", "", ll, flags=re.S)
    loads, args, k = [], [], 0
    for t in ptypes:
        if t == "i8*":
            op = k // 2
            loads_name = "%%opnd%d" % op
            if k % 2 == 0:
                loads.append("  %%ra%d = add i32 %%lp, %d\n"
                             "  %%pa%d = inttoptr i32 %%ra%d to i32*\n"
                             "  %%va%d = load i32, i32* %%pa%d, align 4\n"
                             "  %s = inttoptr i32 %%va%d to i8*\n" % (
                                 op, RECORD_BYTES * op, op, op, op, op, loads_name, op))
            args.append("i8* " + loads_name)
            k += 1
        else:
            args.append(t + " 0")
    shim = (
        "\ndefine void @generated_0(i32 %lp) {\n"
        "entry:\n"
        + "".join(loads) +
        "  call RET @__impl_generated_0(ARGS)\n"
        "  ret void\n}\n"
    ).replace("RET", ret).replace("ARGS", ", ".join(args))
    return ll + shim, n_ops


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    abi = sys.argv[3] if len(sys.argv) > 3 else "act"
    with open(src) as fh:
        mlir = kernel_only(fh.read())
    ll = legacy_attrs(typed(translate(mlir)))
    n_ops = None
    if abi == "act":
        ll, n_ops = act_shim(ll)
    with open(dst, "w") as fh:
        fh.write(ll)
    print("wrote", dst, "abi=" + abi, "operands=%s" % (n_ops,))


if __name__ == "__main__":
    main()
