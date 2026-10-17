#!/usr/bin/env python3
# cil-link.py: link qbe2cil.py fragments into one CIL executable (the nfcc `cil` backend; docs/notes/cil.md).
#
#   cil-link.py -o OUT FRAGMENT... (ILASM=path/to/ilasm, default build/cil/ilasm)
#
# Writes OUT (a shell launcher), OUT.dll and OUT.runtimeconfig.json. Run with `dotnet OUT.dll` or OUT.
# Everything lives in one static class `Prog`: functions are methods, global symbols are static fields `addr_<name>`
# holding the address (int64), and Init() allocates the data, fills it in and runs the constructors. Calls to a
# function no unit defines become P/Invoke stubs (libc.so.6, or libm.so.6 for the math functions). Data no unit
# defines is found with dlsym at Init. The entry point calls Init, builds argv = {"<program>", NULL}, and calls main.
import json
import os
import re
import subprocess
import sys
import tempfile

LIBM = {'sqrt', 'sin', 'cos', 'tan', 'asin', 'acos', 'atan', 'atan2', 'exp', 'exp2', 'log', 'log2', 'log10', 'pow',
        'floor', 'ceil', 'round', 'trunc', 'fmod', 'fabs', 'hypot', 'cbrt', 'sinh', 'cosh', 'tanh', 'fmin', 'fmax',
        'copysign', 'ldexp', 'frexp', 'modf', 'sqrtf', 'sinf', 'cosf', 'powf', 'fabsf', 'floorf', 'ceilf', 'roundf',
        'fmodf', 'expf', 'logf'}
NOOP_INTRINSICS = {'__nfcxx_fence', '__nfcxx_int3'}  # the x86 fence and int3 stubs of qbe-prep.rb (no CIL form)
RUNTIME = '8.0.0'


def die(msg):
    sys.exit('cil-link: ' + msg)


def ilasm_path():
    p = os.environ.get('ILASM') or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'build', 'cil', 'ilasm')
    if not os.path.exists(p):
        die(f'ilasm not found at {p} (run scripts/setup-cil.sh, or set ILASM)')
    return p


def sig_str(sig):
    return f"{sig['ret']}({', '.join(sig['params'])})"


def qname(name):
    return name.replace("'", "\\'")


# name -> (IL return type, parameter IL types, body): the runtime of the C++ exceptions on CIL.
CXX_RUNTIME = {
    '_setjmp': ('int32', ['int64'], ['ldc.i4.0', 'ret']),
    '__throw_setup': ('int64', ['int64', 'int64', 'int32'],
                      ["ldc.i8 1", 'ldarg.1', "call int64 Prog::'calloc'(int64, int64)", "dup",
                       "stsfld int64 Prog::'cxx_ptr'", 'ret']),
    '__throw': ('void', [], ['newobj instance void class CxxThrow::.ctor()', 'throw']),
    '__rethrow': ('void', [], ['newobj instance void class CxxThrow::.ctor()', 'throw']),
    '__exception_caught': ('void', [], ['ret']),
    '__destroy_exception_object': ('void', [], ['ret']),
}

SHIM_C = r"""#define _GNU_SOURCE
#include <dlfcn.h>
/* Calls the named function through a variadic prototype, so the SysV ABI sees the vector registers in use (%al). */
typedef long (*nfcxx_vfn)(long, long, long, long, long, long, ...);
long nfcxx_vcall(const char *name, long i0, long i1, long i2, long i3, long i4, long i5,
                 double d0, double d1, double d2, double d3, double d4, double d5, double d6, double d7,
                 long s0, long s1, long s2, long s3, long s4, long s5, long s6, long s7) {
    nfcxx_vfn fn = (nfcxx_vfn)dlsym(RTLD_DEFAULT, name);
    return fn(i0, i1, i2, i3, i4, i5, d0, d1, d2, d3, d4, d5, d6, d7, s0, s1, s2, s3, s4, s5, s6, s7);
}
"""


def build_shim(dirname):
    cc = os.environ.get('CC', 'cc')
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, 'libnfcxx_va.c')
        with open(src, 'w') as fh:
            fh.write(SHIM_C)
        r = subprocess.run([cc, '-shared', '-fPIC', '-O2', '-o', os.path.join(dirname, 'libnfcxx_va.so'), src, '-ldl'],
                           capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(r.stderr)
            die('building the variadic call shim failed')


def main():
    out, paths, args = None, [], sys.argv[1:]
    i = 0
    while i < len(args):
        a = args[i]
        if a == '-o':
            out = args[i + 1]
            i += 2
            continue
        if not a.startswith('-'):
            paths.append(a)
        i += 1  # link options (-l, -L, -O, ...) have no meaning for the CIL program
    if out is None:
        die('no -o OUT')
    frags = []
    for path in paths:
        with open(path) as fh:
            frags.append(json.load(fh))
    if not frags:
        die('no input fragments')

    functions, data, calls, addrs, ctors = {}, {}, {}, set(), []
    for fr in frags:
        for fn in fr['functions']:
            if fn['name'] in functions:
                die(f"function {fn['name']} is defined twice")
            functions[fn['name']] = fn
        for d in fr['data']:
            if d['name'] in data:
                die(f"data {d['name']} is defined twice")
            data[d['name']] = d
        for name, sig in fr['calls'].items():
            if name in calls and calls[name] != sig:
                die(f"{name} is called with two signatures: {sig_str(calls[name])} and {sig_str(sig)}")
            calls.setdefault(name, sig)
        addrs.update(fr['addrs'])
        ctors.extend(fr['ctors'])

    # The C++ exception runtime of the Path B CIL spike (docs/notes/pathb-cil.md): a throw stores the object's storage
    # pointer in cxx_ptr and raises CxxThrow; the catch in the emitted IL reads cxx_ptr. Synthesized as functions, so
    # the address and init handling of other functions apply to them.
    used = set(calls) | addrs
    for name, (ret, params, body) in CXX_RUNTIME.items():
        if name in used and name not in functions:
            functions[name] = {'name': name, 'ret': ret, 'params': params, 'exported': True,
                               'il': [f".method static {ret} '{name}'({', '.join(params)}) cil managed {{",
                                      '  .maxstack 4'] + ['    ' + b for b in body] + ['}']}
    cxx_runtime = True  # the class and cxx_ptr are always there: a try in the IR catches CxxThrow

    # Undefined functions: P/Invoke. Intrinsics with no CIL form become empty methods.
    externs = {n: s for n, s in calls.items() if n not in functions}
    noops = {n: s for n, s in externs.items() if n in NOOP_INTRINSICS}
    for n in noops:
        del externs[n]
    for n, s in calls.items():
        if n in functions and functions[n]['ret'] != s['ret']:
            die(f"{n} is defined as returning {functions[n]['ret']} but called as {s['ret']}")
    for n, s in calls.items():
        if n in functions and functions[n]['params'] != s['params'] and not s['variadic']:
            die(f"{n} is defined with {functions[n]['params']} but called with {s['params']}")

    # The program name for argv[0], as a data symbol.
    prog = os.path.basename(out)
    data['__nfcxx_argv0'] = {'name': '__nfcxx_argv0', 'exported': False, 'align': 1, 'size': len(prog) + 1,
                             'items': [['int8', c] for c in prog.encode()] + [['int8', 0]]}

    # Data addresses: every data symbol, every symbol used as a value, and every symbol a data item points at.
    names = set(data) | addrs
    for d in data.values():
        for it in d['items']:
            if it[0] == 'addr':
                names.add(it[1])
    dlsym_names = sorted(n for n in names if n not in data and n not in functions)

    if 'main' not in functions:
        die('no main function')
    main_fn = functions['main']

    lines = []
    emit = lines.append
    emit('.assembly extern System.Runtime { .ver 8:0:0:0 }')
    emit('.assembly nfcxx_program { }')
    emit(f".module '{qname(os.path.basename(out))}.dll'")
    if cxx_runtime:  # declared before its uses (ilasm needs the class first)
        emit('.class public auto ansi CxxThrow extends [System.Runtime]System.Exception {')
        emit('  .method public specialname rtspecialname instance void .ctor() cil managed {')
        for x in ('    ldarg.0', '    call instance void [System.Runtime]System.Exception::.ctor()', '    ret'):
            emit(x)
        emit('  }')
        emit('}')
    emit('.class public abstract sealed auto ansi beforefieldinit Prog extends [System.Runtime]System.Object {')
    for n in sorted(names):
        emit(f"  .field public static int64 'addr_{qname(n)}'")
    if cxx_runtime:
        emit("  .field public static int64 'cxx_ptr'")

    # P/Invoke stubs for the functions this program calls and no unit defines (a variadic call goes through the shim).
    variadic = any(s.get('variadic') for s in calls.values()) or any(fr.get('variadic') for fr in frags)
    for n, s in sorted(externs.items()):
        if s.get('variadic'):
            continue
        lib = 'libm.so.6' if n in LIBM else 'libc.so.6'
        ps = ', '.join(s['params'])
        emit(f"  .method public static pinvokeimpl(\"{lib}\" as \"{n}\") {s['ret']} '{qname(n)}'({ps}) "
             f"cil managed preservesig {{ }}")
    for n, s in sorted(noops.items()):
        ps = s['params']
        body = ['ret'] if s['ret'] == 'void' else (['ldc.i4.0', 'ret'] if s['ret'] == 'int32' else ['ldc.i8.0', 'ret'])
        emit(f"  .method static {s['ret']} '{qname(n)}'({', '.join(ps)}) cil managed {{ .maxstack 2 "
             + ' '.join(body) + ' }')
    if variadic:
        floats = ', '.join(['float64'] * 8)
        ints = ', '.join(['int64'] * 8)
        emit('  .method public static pinvokeimpl("libnfcxx_va" as "nfcxx_vcall") int64 \'nfcxx_vcall\'(string, '
             'int64, int64, int64, int64, int64, int64, ' + floats + ', ' + ints + ') cil managed preservesig { }')
    # The libc functions the runtime itself uses.
    for n, sig in [('calloc', ('int64', ['int64', 'int64'])), ('dlsym', ('int64', ['int64', 'string'])),
                   ('strdup', ('int64', ['string']))]:
        ps = ', '.join(sig[1])
        emit(f"  .method public static pinvokeimpl(\"libc.so.6\" as \"{n}\") {sig[0]} '{n}'({ps}) "
             f"cil managed preservesig {{ }}")

    # Functions.
    for fn in functions.values():
        emit('\n'.join(fn['il']))

    # Init: allocate, fill addresses, write the data, run the constructors.
    init = ['.method static void Init() cil managed {', '  .maxstack 1024']
    init.append('  .locals init (int64 V0)')
    for n, d in sorted(data.items()):
        init += [f"    ldc.i8 {max(d['size'], 1)}", '    ldc.i8 1', "    call int64 Prog::'calloc'(int64, int64)",
                 f"    stsfld int64 Prog::'addr_{qname(n)}'"]
    for n in dlsym_names:
        init += ['    ldc.i8 0', f"    ldstr \"{n}\"", "    call int64 Prog::'dlsym'(int64, string)",
                 f"    stsfld int64 Prog::'addr_{qname(n)}'"]
    for n in sorted(names):
        if n in functions and n not in data:
            fn = functions[n]
            init += [f"    ldftn {fn['ret']} Prog::'{qname(n)}'({', '.join(fn['params'])})", '    conv.u8',
                     f"    stsfld int64 Prog::'addr_{qname(n)}'"]
    for n, d in sorted(data.items()):
        off = 0
        for it in d['items']:
            kind = it[0]
            if kind == 'zero':
                off += it[1]
                continue
            base = [f"    ldsfld int64 Prog::'addr_{qname(n)}'", f'    ldc.i8 {off}', '    add', '    conv.u']
            if kind == 'addr':
                init += base
                init += [f"    ldsfld int64 Prog::'addr_{qname(it[1])}'", f'    ldc.i8 {it[2]}', '    add',
                         '    stind.i8']
                off += 8
                continue
            width = {'int8': 1, 'int16': 2, 'int32': 4, 'int64': 8, 'float32': 4, 'float64': 8}[kind]
            if kind in ('float32', 'float64'):
                raw = it[1].to_bytes(width, 'little')
                if kind == 'float32':
                    init += base + ['    ldc.r4 (' + ' '.join(f'{b:02x}' for b in raw) + ')', '    stind.r4']
                else:
                    init += base + ['    ldc.r8 (' + ' '.join(f'{b:02x}' for b in raw) + ')', '    stind.r8']
            elif kind == 'int64':
                init += base + [f'    ldc.i8 {it[1]}', '    stind.i8']
            else:
                suffix = {'int8': 'i1', 'int16': 'i2', 'int32': 'i4'}[kind]
                init += base + [f'    ldc.i4 {it[1]}', f'    stind.{suffix}']
            off += width
    for c in ctors:
        if c in functions:
            init.append(f"    call void Prog::'{qname(c)}'()")
    init.append('    ret')
    init.append('}')
    emit('\n'.join(init))

    # The entry point: Init, argv (the program name, then the arguments after the .dll), main.
    ps = main_fn['params']
    entry = ['.method static int32 EntryPoint() cil managed {', '  .entrypoint', '  .maxstack 1024',
             '  .locals init (int64 V0, string[] V1, int32 V2, int32 V3)', '    call void Prog::Init()']
    if ps:
        if ps != ['int32', 'int64']:
            die(f'main takes {ps}; only main(void) and main(int, char **) are supported')
        entry += [
            # args = Environment.GetCommandLineArgs(): the .dll path, then the arguments; argc = its length
            '    call string[] [System.Runtime]System.Environment::GetCommandLineArgs()', '    stloc.1',
            '    ldloc.1', '    ldlen', '    conv.i4', '    stloc.2',
            '    ldloc.2', '    conv.i8', '    ldc.i8 1', '    add', '    ldc.i8 8', '    mul', '    ldc.i8 1',
            "    call int64 Prog::'calloc'(int64, int64)", '    stloc.0',
            '    ldloc.0', '    conv.u', "    ldsfld int64 Prog::\'addr___nfcxx_argv0\'", '    stind.i8',
            '    ldc.i4.1', '    stloc.3',
            'IL_argv_loop:', '    ldloc.3', '    ldloc.2', '    bge IL_argv_done',
            '    ldloc.0', '    ldloc.3', '    conv.i8', '    ldc.i8 8', '    mul', '    add', '    conv.u',
            '    ldloc.1', '    ldloc.3', '    ldelem.ref', "    call int64 Prog::'strdup'(string)", '    stind.i8',
            '    ldloc.3', '    ldc.i4.1', '    add', '    stloc.3', '    br IL_argv_loop',
            'IL_argv_done:',
            '    ldloc.2', '    ldloc.0', "    call int32 Prog::'main'(int32, int64)"]
    else:
        entry += ["    call int32 Prog::'main'()"] if main_fn['ret'] == 'int32' else [
            "    call void Prog::'main'()", '    ldc.i4.0']
    if ps and main_fn['ret'] != 'int32':
        entry += ['    pop', '    ldc.i4.0']
    entry += ['    ret', '}']
    emit('\n'.join(entry))
    emit('}')

    if variadic:
        build_shim(os.path.dirname(os.path.abspath(out)))
    with tempfile.TemporaryDirectory() as tmp:
        il_path = os.path.join(tmp, 'prog.il')
        with open(il_path, 'w') as fh:
            fh.write('\n'.join(lines) + '\n')
        dll = out + '.dll'
        if os.environ.get('NFCXX_KEEP_IL'):  # debugging: keep the CIL text next to the output
            with open(out + '.il', 'w') as fh:
                fh.write('\n'.join(lines) + '\n')
        r = subprocess.run([ilasm_path(), '-exe', f'-output={dll}', il_path], capture_output=True, text=True)
        if r.returncode != 0:
            sys.stderr.write(r.stdout + r.stderr)
            with open(out + '.failed.il', 'w') as fh:
                fh.write('\n'.join(lines) + '\n')
            die(f'ilasm failed (the IL is in {out}.failed.il)')
    with open(out + '.runtimeconfig.json', 'w') as fh:
        json.dump({'runtimeOptions': {'tfm': 'net8.0', 'rollForward': 'LatestMajor',
                                      'framework': {'name': 'Microsoft.NETCore.App', 'version': RUNTIME}}}, fh)
    with open(out, 'w') as fh:
        fh.write('#!/bin/sh\nexec dotnet "$(dirname "$0")/' + os.path.basename(dll) + '" "$@"\n')
    os.chmod(out, 0o755)


if __name__ == '__main__':
    main()
