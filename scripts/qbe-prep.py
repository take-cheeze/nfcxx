#!/usr/bin/env python3
"""Rewrite EDG's preprocessed C so cproc accepts it, and emit the assembly the C cannot express.

cproc (the QBE front end) rejects a few GNU forms that EDG emits. This script tokenizes the
preprocessed C and rewrites only those forms; everything else passes through unchanged:

  * `__asm__ volatile("int $3\n" : :);` (doctest's DOCTEST_BREAK_INTO_DEBUGGER, a statement with
    no operands) becomes a call to `__nfcxx_int3()`. The assembly tail defines it as a weak
    `int3; ret` stub, so the trap is the same and the program resumes after it. Any other inline asm
    is left in place, and cproc rejects it.
  * Builtins cproc does not know, which doctest uses. `__builtin_memcpy`, `memmove`, `memset`, `memcmp` and
    `strlen` are renamed to the libc functions, with prototypes in the prelude. `__builtin_isnan` and
    `__builtin_clzl` become small helpers (`__nfcxx_isnan`, `__nfcxx_clzl`), defined in the prelude.
    `__builtin_mul_overflow(x, C, &x)` with an unsigned long decimal constant C (the only shape doctest
    uses; `(&x)` also accepted) becomes `__nfcxx_mulov_ul`, a checked multiply with the same result.
    Other uses of these builtins, and every other builtin, are left alone, so cproc rejects them.
  * `__builtin_{add,sub,mul}_overflow(a, b, &r)` in general (mruby's numeric.h and time gem), when `a`, `b`
    and `*r` all have the same type among int, unsigned, long, unsigned long, long long, unsigned long long
    (a literal is an int or long like any other operand): nested `_Generic`s pick a small
    helper function (`__nfcxx_addov_l`, ...) that computes the wrapped result and the overflow flag. Any other
    mix of integer types (and literals, and char/short operands or results) goes through `__nfcxx_ovx`, which
    computes the exact result in sign and 128-bit magnitude as GCC does and reports whether `*r` can hold it.
    A non-integer operand or result selects `__nfcxx_overflow_unsupported_operand_types`, declared and never
    defined: a link error naming that symbol, never a silently converted operand.
  * `(double)1.5e308L` / `(float)...L` (hand-written C): glibc's <float.h> spells DBL_MIN, DBL_MAX and DBL_EPSILON
    this way (`((double)2.2250738585072014e-308L)`). cproc types the literal as long double and emits an invalid
    QBE `truncd` for the cast. The `L` is dropped when the literal is directly cast to double or float, which
    rounds the same decimal to the target format. A long double literal anywhere else is left alone.
  * `alloca(n)` (hand-written C only; glibc's <alloca.h> declares a function when `__GNUC__` is unset, and libc
    has no such symbol) becomes cproc's `__builtin_alloca(n)`. A declaration (`... *alloca(...)`) is left alone.
  * `__builtin_popcount{,l,ll}`, `__builtin_ctz{,l,ll}`, `__builtin_clz{,ll}` become helper functions
    (like `__builtin_clzl` above). For a zero argument ctz and clz return the width; GCC leaves that undefined.
  * Sized atomics `__atomic_{load,store,exchange,compare_exchange,fetch_OP,OP_fetch}_{1,2,4,8}` (what
    libstdc++'s std::atomic calls) get prototypes for the libatomic functions of the same name. The QBE
    link adds -latomic (scripts/qbe-cc). The 16-byte forms are left alone; they need __int128.
  * `__asm__(".align 2");` alignment hints (anywhere): dropped, as the old sed did. The hint
    only matters to EDG's own output, and it is not a semantic change.
  * Top-level `__asm__("...")` statements (not declarator labels) are removed from the C and
    re-emitted in the assembly tail: `.global X` / `.globl X` become `.globl X`, and `X = Y`
    becomes `.set X, Y`. EDG uses these for thread_local initialization aliases
    (`_ZTHx = __tls_init`). A `_ZTHx` alias is marked `.weak` when its `_ZTWx` wrapper is weak
    (COMDAT), as gcc does.
  * `__attribute__((__constructor__))` on a function declaration (EDG's static initializers, `__sti_*`)
    is removed from the C, and the function is listed in `.init_array` in the assembly tail, so the
    C runtime runs it before main. Only the plain form is handled; a priority argument is left alone.
  * `__attribute__((__aligned__(N)))` after an array declarator (`T x[40] __attribute__(...)`)
    moves to just after the declared name, where cproc accepts it. Same alignment.
  * `struct T {char b[L];} __attribute__((__aligned__(N)))` (std::aligned_storage) becomes
    `struct T {_Alignas(N) char b[L];}`. Only when L is a multiple of N, so the size does not change.
  * Floating types cproc lacks: `__bf16` and `_Float16` (2 bytes) and `_Float128` (16 bytes) become
    structs with the same size and alignment and no arithmetic, so a real use of the value is a
    compile error rather than a silent mis-typed float. `_Float32` and `_Float64` are IEEE binary32
    and binary64, the same formats as `float` and `double` on x86-64, so they map to those.
    libstdc++'s std::numbers variables (pulled in by <map>) use all of them. Their literals
    (`2.71875f16`) are rewritten to the exact bit pattern (`f16`, `f128`), or to a plain
    `float`/`double` literal (`f32`, `f64`).
  * Hand-written C (env NFCXX_C_INPUT=1, set by nfcxx for .c inputs; glibc headers and user code):
    `volatile` is dropped (cproc errors on any store to a volatile object; it already emits volatile loads
    as plain loads; a volatile block-scope local gets `__nfcxx_keep(&x);` after its declaration so QBE keeps
    it in memory across setjmp/longjmp), and `typedef T _Float32;`-style typedefs of the floating types above are removed
    (the names are mapped instead), as glibc's <bits/floatn.h> declares them.

Usage: qbe-prep.py PREPROCESSED_C REWRITTEN_C ASM_TAIL
ASM_TAIL is appended to the QBE assembly by qbe-cc.
"""
import os
import re
import sys
from fractions import Fraction

TOKEN_RE = re.compile(r'''
  (?P<ws>\s+)
| (?P<comment>//[^\n]*|/\*.*?\*/)
| (?P<str>(?:u8|[LuU])?"(?:[^"\\\n]|\\.)*")
| (?P<chr>(?:[LuU])?'(?:[^'\\\n]|\\.)*')
| (?P<num>\.?\d(?:[eEpP][+-]|[\w.])*)
| (?P<id>[A-Za-z_$]\w*)
| (?P<punct>.)
''', re.S | re.X)

FLOAT_TYPE = {
    '_Float32': 'float',
    '_Float64': 'double',
    '__bf16': 'struct __nfcxx_half16',
    '_Float16': 'struct __nfcxx_half16',
    '_Float128': 'struct __nfcxx_float128',
}
C_INPUT = bool(os.environ.get('NFCXX_C_INPUT'))
DROP_TYPEDEF = set(FLOAT_TYPE) | {'_Float32x', '_Float64x', '_Float128x'}
FLOAT_DECL = {
    'struct __nfcxx_half16': 'struct __nfcxx_half16 { unsigned short bits; };',
    'struct __nfcxx_float128': 'struct __nfcxx_float128 { _Alignas(16) unsigned long bits[2]; };',
}
FLOAT_LIT = re.compile(r'(\.?\d[\d.]*(?:[eE][+-]?\d+)?)(f16|f32|f64|f128)')


def ieee_bits(lit, mant, ebits):
    """Bit pattern of the decimal literal LIT in an IEEE binary format (round to nearest even)."""
    x = Fraction(lit)
    bias = 2 ** (ebits - 1) - 1
    sign = 1 if x < 0 else 0
    x = abs(x)
    if x == 0:
        return sign << (mant + ebits)
    e = x.numerator.bit_length() - x.denominator.bit_length()
    if Fraction(2) ** e > x:
        e -= 1
    if Fraction(2) ** (e + 1) <= x:
        e += 1
    m = round(x / Fraction(2) ** (e - mant))
    if m == 2 ** (mant + 1):
        m //= 2
        e += 1
    if e < 1 - bias or e + bias >= 2 ** ebits - 1:
        sys.exit(f'qbe-prep: literal {lit} is out of range for this format (subnormal or overflow)')
    return (sign << (mant + ebits)) | ((e + bias) << mant) | (m - 2 ** mant)


class Tok:
    __slots__ = ('kind', 'text', 'start', 'end', 'depth', 'pdepth')

    def __init__(self, kind, text, start, end):
        self.kind, self.text, self.start, self.end = kind, text, start, end
        self.depth = 0   # brace depth before this token
        self.pdepth = 0  # paren depth before this token


def tokenize(src):
    toks = []
    for m in TOKEN_RE.finditer(src):
        kind = m.lastgroup
        if kind in ('ws', 'comment'):
            continue
        toks.append(Tok(kind, m.group(), m.start(), m.end()))
    braces = parens = 0
    for t in toks:
        t.depth = braces
        t.pdepth = parens
        if t.kind == 'punct':
            if t.text == '{':
                braces += 1
            elif t.text == '}':
                braces -= 1
            elif t.text == '(':
                parens += 1
            elif t.text == ')':
                parens -= 1
    return toks


def is_punct(t, s):
    return t is not None and t.kind == 'punct' and t.text == s


def tok_at(toks, i):
    return toks[i] if 0 <= i < len(toks) else None


def match_back(toks, i, open_s, close_s):
    """Index of the token matching the close token at i, searching backwards."""
    level = 0
    for j in range(i, -1, -1):
        if is_punct(toks[j], close_s):
            level += 1
        elif is_punct(toks[j], open_s):
            level -= 1
            if level == 0:
                return j
    return -1


def match_fwd(toks, i, open_s, close_s):
    level = 0
    for j in range(i, len(toks)):
        if is_punct(toks[j], open_s):
            level += 1
        elif is_punct(toks[j], close_s):
            level -= 1
            if level == 0:
                return j
    return -1


def aligned_group(toks, i):
    """If toks[i] starts __attribute__((__aligned__(N))), return (end_index_exclusive, N)."""
    if i + 8 >= len(toks) or toks[i].kind != 'id' or toks[i].text != '__attribute__':
        return None
    seq = toks[i + 1:i + 9]
    if not (is_punct(seq[0], '(') and is_punct(seq[1], '(') and seq[2].kind == 'id'
            and seq[2].text in ('__aligned__', 'aligned') and is_punct(seq[3], '(')
            and seq[4].kind == 'num' and is_punct(seq[5], ')') and is_punct(seq[6], ')')
            and is_punct(seq[7], ')')):
        return None
    return i + 9, int(seq[4].text, 0)


def decode_str(lit):
    body = lit[lit.index('"') + 1:-1]
    return body.encode('latin-1', 'backslashreplace').decode('unicode_escape')


INT3_TEXT = ('int $3\n', 'int $3')
INT3_STUB = """\t.pushsection .text.__nfcxx_int3,"ax",@progbits
\t.weak __nfcxx_int3
\t.type __nfcxx_int3,@function
__nfcxx_int3:
\tint3
\tret
\t.popsection"""


LIBC_BUILTINS = {  # builtin -> (libc function, prototype); cproc has the builtin names but not the functions
    '__builtin_memcpy': ('memcpy', 'void *memcpy(void *, const void *, unsigned long);'),
    '__builtin_memmove': ('memmove', 'void *memmove(void *, const void *, unsigned long);'),
    '__builtin_memset': ('memset', 'void *memset(void *, int, unsigned long);'),
    '__builtin_memcmp': ('memcmp', 'int memcmp(const void *, const void *, unsigned long);'),
    '__builtin_strlen': ('strlen', 'unsigned long strlen(const char *);'),
}
HELPER_BUILTINS = {  # builtin -> (helper name, definition in the prelude)
    '__builtin_isnan': ('__nfcxx_isnan',
                        'static int __nfcxx_isnan(double x) { return x != x; }'),
    '__builtin_clzl': ('__nfcxx_clzl',
                       'static int __nfcxx_clzl(unsigned long x) {'
                       ' if (x == 0) return 64; int n = 0; while (!(x >> 63)) { x <<= 1; ++n; } return n; }'),
}
def bit_helpers():
    h = {}
    for suffix, t, bits in (('', 'unsigned int', 32), ('l', 'unsigned long', 64), ('ll', 'unsigned long long', 64)):
        h['__builtin_popcount' + suffix] = (
            '__nfcxx_popcount' + suffix,
            f'static int __nfcxx_popcount{suffix}({t} x) {{ int n = 0; while (x) {{ x &= x - 1; ++n; }} return n; }}')
        h['__builtin_ctz' + suffix] = (
            '__nfcxx_ctz' + suffix,
            f'static int __nfcxx_ctz{suffix}({t} x) {{ int n = 0; if (x == 0) return {bits};'
            f' while (!(x & 1)) {{ x >>= 1; ++n; }} return n; }}')
        if suffix != 'l':  # clzl is defined above
            h['__builtin_clz' + suffix] = (
                '__nfcxx_clz' + suffix,
                f'static int __nfcxx_clz{suffix}({t} x) {{ if (x == 0) return {bits}; int n = 0;'
                f' while (!(x >> {bits - 1})) {{ x <<= 1; ++n; }} return n; }}')
    return h


HELPER_BUILTINS.update(bit_helpers())

# Type-generic overflow builtins: (C type, helper suffix, unsigned counterpart of a signed type).
OV_TYPES = (('int', 'i', 'unsigned int'), ('unsigned int', 'u', None), ('long', 'l', 'unsigned long'),
            ('unsigned long', 'ul', None), ('long long', 'll', 'unsigned long long'),
            ('unsigned long long', 'ull', None))
OV_BAD = '__nfcxx_overflow_unsupported_operand_types'
OV_OPS = {'__builtin_add_overflow': 'add', '__builtin_sub_overflow': 'sub', '__builtin_mul_overflow': 'mul'}


def ov_helper(op, t, suf, u):
    """(name, definition) of the overflow helper for OP on type T; U is the unsigned counterpart of a signed T."""
    name = f'__nfcxx_{op}ov_{suf}'
    head = f'static int {name}({t} a, {t} b, {t} *r) {{ '
    if u is None:
        body = {'add': '*r = a + b; return *r < a;',
                'sub': '*r = a - b; return a < b;',
                'mul': '*r = a * b; return a != 0 && *r / a != b;'}[op]
    else:
        mn = f'(({t})(({u})1 << (sizeof({t}) * 8 - 1)))'
        body = {'add': f'{u} s = ({u})a + ({u})b; *r = ({t})s; return ((a ^ ({t})s) & (b ^ ({t})s)) < 0;',
                'sub': f'{u} s = ({u})a - ({u})b; *r = ({t})s; return ((a ^ b) & (a ^ ({t})s)) < 0;',
                'mul': f'{u} p = ({u})a * ({u})b; *r = ({t})p; if (a == 0 || b == 0) return 0;'
                       f' if (a == -1) return b == {mn}; if (b == -1) return a == {mn}; return ({t})p / a != b;'}[op]
    return name, head + body + ' }'


def split_args(toks, lp):
    """Top-level argument token ranges of the call whose '(' is toks[lp]; returns (ranges, index of the ')')."""
    rp = match_fwd(toks, lp, '(', ')')
    if rp < 0:
        return None, -1
    ranges, start, level = [], lp + 1, 0
    for k in range(lp + 1, rp):
        t = toks[k]
        if t.kind == 'punct':
            if t.text in '([{':
                level += 1
            elif t.text in ')]}':
                level -= 1
            elif t.text == ',' and level == 0:
                ranges.append((start, k))
                start = k + 1
    ranges.append((start, rp))
    return ranges, rp


VOLATILE_QUALS = ('volatile', '__volatile__', '__volatile')
KEEP_NAME = '__nfcxx_keep'
KEEP_DEF = f'static void {KEEP_NAME}(void *p) {{ }}'


def volatile_locals(toks):
    """Edits that keep volatile block-scope locals in memory (C inputs; the qualifier itself is dropped later).

    QBE promotes a stack slot to a register unless its address escapes, so a volatile local that is written
    after setjmp and read after longjmp would be stale. After each declaration of such a local this adds
    `__nfcxx_keep(&x);` (a call to an empty function in the prelude), which makes the address escape.
    Skipped: arrays, function pointers and function declarations, typedef/static/extern/register
    declarations, `for` declarations and function parameters (none of which need it or can take it)."""
    edits = []
    stack = []  # 'func', 'block' or 'other' for each open brace
    seen = set()
    for i, t in enumerate(toks):
        if t.kind == 'punct':
            if t.text == '{':
                prev = tok_at(toks, i - 1)
                if not stack:
                    stack.append('func' if is_punct(prev, ')') else 'other')
                elif stack[-1] == 'other':
                    stack.append('other')
                elif prev is None or (prev.kind == 'punct' and prev.text in (';', '{', '}', ')', ':')) or (
                        prev.kind == 'id' and prev.text in ('else', 'do')):
                    stack.append('block')
                else:
                    stack.append('other')
            elif t.text == '}' and stack:
                stack.pop()
            continue
        if t.kind != 'id' or t.text not in VOLATILE_QUALS:
            continue
        if not stack or stack[-1] == 'other' or t.pdepth != 0:
            continue
        # A declaration: only identifiers and `*` between the statement start and the qualifier.
        s = i
        while s > 0 and not (toks[s - 1].kind == 'punct' and toks[s - 1].text in (';', '{', '}')):
            s -= 1
        if s in seen or not all(x.kind == 'id' or is_punct(x, '*') for x in toks[s:i]):
            continue
        seen.add(s)
        e, level = i, 0  # e: the terminating `;`
        while e < len(toks):
            x = toks[e]
            if x.kind == 'punct':
                if x.text in '([{':
                    level += 1
                elif x.text in ')]}':
                    level -= 1
                    if level < 0:
                        break
                elif x.text == ';' and level == 0:
                    break
            e += 1
        if e >= len(toks) or level < 0:
            continue
        if any(x.kind == 'id' and x.text in ('typedef', 'static', 'extern', 'register', '_Thread_local', '__thread')
               for x in toks[s:e]):
            continue
        pieces, cur, level = [], [], 0
        for x in toks[s:e]:
            if x.kind == 'punct':
                if x.text in '([{':
                    level += 1
                elif x.text in ')]}':
                    level -= 1
                elif x.text == ',' and level == 0:
                    pieces.append(cur)
                    cur = []
                    continue
            cur.append(x)
        pieces.append(cur)
        names, base_vol = [], False
        for n, piece in enumerate(pieces):
            decl = []
            for x in piece:
                if is_punct(x, '='):
                    break
                decl.append(x)
            stars = [k for k, x in enumerate(decl) if is_punct(x, '*')]
            vols = [k for k, x in enumerate(decl) if x.kind == 'id' and x.text in VOLATILE_QUALS]
            if n == 0:
                base_vol = any(not stars or k < stars[0] for k in vols)
            if any(is_punct(x, '(') or is_punct(x, '[') for x in decl):
                continue
            ids = [x for x in decl if x.kind == 'id']
            vol = any(k > stars[-1] for k in vols) if stars else base_vol
            if vol and ids:
                names.append(ids[-1].text)
        if names:
            edits.append((toks[e].end, toks[e].end, ''.join(f' {KEEP_NAME}(&{nm});' for nm in names)))
    return edits


# Result types of the general (mixed-operand) overflow lowering: (C type, bits, signed).
OVX_TYPES = (('signed char', 8, 1), ('unsigned char', 8, 0), ('short', 16, 1), ('unsigned short', 16, 0),
             ('int', 32, 1), ('unsigned int', 32, 0), ('long', 64, 1), ('unsigned long', 64, 0),
             ('long long', 64, 1), ('unsigned long long', 64, 0))
OVX_CORE = """static int __nfcxx_ovx(int op, unsigned long long a, int as, unsigned long long b, int bs, int w, int rs, unsigned long long *out) {
  int an = as && (long long)a < 0, bn = bs && (long long)b < 0, neg;
  unsigned long long am = an ? -a : a, bm = bn ? -b : b, hi = 0, lo;
  if (op == 2) {
    unsigned long long a0 = am & 0xffffffffULL, a1 = am >> 32, b0 = bm & 0xffffffffULL, b1 = bm >> 32;
    unsigned long long p00 = a0 * b0, p01 = a0 * b1, p10 = a1 * b0, p11 = a1 * b1;
    unsigned long long mid = (p00 >> 32) + (p01 & 0xffffffffULL) + (p10 & 0xffffffffULL);
    lo = (p00 & 0xffffffffULL) | (mid << 32);
    hi = p11 + (p01 >> 32) + (p10 >> 32) + (mid >> 32);
    neg = an != bn;
  } else {
    if (op == 1) bn = !bn;
    if (an == bn) { lo = am + bm; hi = lo < am; neg = an; }
    else if (am >= bm) { lo = am - bm; neg = an; }
    else { lo = bm - am; neg = bn; }
  }
  if (hi == 0 && lo == 0) neg = 0;
  *out = neg ? -lo : lo;
  if (hi) return 1;
  if (rs) return neg ? lo > (1ULL << (w - 1)) : lo > (1ULL << (w - 1)) - 1;
  if (neg) return 1;
  return w < 64 && (lo >> w) != 0;
}"""
OV_OPNUM = {'add': 0, 'sub': 1, 'mul': 2}


def overflow_call(op, text, prelude):
    """C expression for __builtin_OP_overflow(a, b, r) given the argument texts.

    The result is the exact value a OP b converted (wrapping) to *r, the flag is whether that value differs, as in GCC.
    Same-type int/long/long long operands use the small helpers; every other mix of integer operand
    types (literals included) goes through __nfcxx_ovx, which computes in sign and 128-bit magnitude."""
    a, b, r = text
    prelude['__nfcxx_ovx'] = OVX_CORE
    prelude[OV_BAD] = f'int {OV_BAD}(long long, ...);'
    sg = lambda x: (f'_Generic((({x})+0), int: 1, long: 1, long long: 1, unsigned: 0, unsigned long: 0,'
                    f' unsigned long long: 0, default: {OV_BAD}(0))')
    fast = {ty: (suf, u) for ty, suf, u in OV_TYPES}
    cases = []
    for ty, bits, signed in OVX_TYPES:
        wname = '__nfcxx_ovx_' + ty.replace(' ', '_')
        prelude[wname] = (f'static int {wname}(int op, unsigned long long a, int as, unsigned long long b, int bs, {ty} *r) {{'
                          f' unsigned long long o; int f = __nfcxx_ovx(op, a, as, b, bs, {bits}, {signed}, &o); *r = ({ty})o; return f; }}')
        mix = f'{wname}({OV_OPNUM[op]}, (unsigned long long)({a}), {sg(a)}, (unsigned long long)({b}), {sg(b)}, ({ty} *)({r}))'
        sel = mix
        if ty in fast:
            hname, hdef = ov_helper(op, ty, *fast[ty])
            prelude[hname] = hdef
            sel = (f'_Generic(({a}), {ty}: _Generic(({b}), {ty}: {hname}({a}, {b}, ({ty} *)({r})), default: {mix}), default: {mix})')
        cases.append(f'{ty} *: {sel}')
    return f'_Generic(({r}), ' + ', '.join(cases) + f', default: {OV_BAD}(0, {a}, {b}, {r}))'


MULOV_NAME = '__nfcxx_mulov_ul'
MULOV_DEF = ('static int __nfcxx_mulov_ul(unsigned long a, unsigned long b, unsigned long *r) {'
             ' unsigned long p = a * b; *r = p; return a != 0 && p / a != b; }')
UL_CONST = re.compile(r'\d+(?:[uU][lL]|[lL][uU])')
# GCC's sized atomics for 1, 2, 4 and 8 bytes (libstdc++'s std::atomic calls them). GCC inlines them; cproc has
# no atomics, so they are calls to the functions libatomic exports (GCC 13 has all of them; 16 bytes needs
# __int128, which cproc lacks, so it is left out and fails loudly). The memory-order arguments are passed on.
ATOMIC_RE = re.compile(r'__atomic_(load|store|exchange|compare_exchange|fetch_(?:add|sub|and|or|xor|nand)'
                       r'|(?:add|sub|and|or|xor|nand)_fetch)_([1248])')
ATOMIC_TYPE = {'1': 'unsigned char', '2': 'unsigned short', '4': 'unsigned int', '8': 'unsigned long'}


def atomic_prototype(name):
    op, size = ATOMIC_RE.fullmatch(name).groups()
    t = ATOMIC_TYPE[size]
    if op == 'load':
        return f'{t} {name}(const volatile void *, int);'
    if op == 'store':
        return f'void {name}(volatile void *, {t}, int);'
    if op == 'compare_exchange':  # EDG passes GCC's six arguments; libatomic reads the first three (always seq_cst)
        return f'_Bool {name}(volatile void *, void *, {t}, _Bool, int, int);'
    return f'{t} {name}(volatile void *, {t}, int);'  # exchange, fetch_OP and OP_fetch: (ptr, value, order)


def mulov_const_shape(toks, lp):
    """True if toks[lp] is the '(' of `( x , C , &x )` (or `( x , C , (&x) )`), x an identifier and C an unsigned long constant."""
    if not is_punct(tok_at(toks, lp), '('):
        return False
    k = lp + 1
    x = tok_at(toks, k)
    if x is None or x.kind != 'id' or not is_punct(tok_at(toks, k + 1), ','):
        return False
    c = tok_at(toks, k + 2)
    if c is None or c.kind != 'num' or not UL_CONST.fullmatch(c.text) or not is_punct(tok_at(toks, k + 3), ','):
        return False
    k += 4
    paren = is_punct(tok_at(toks, k), '(')
    if paren:
        k += 1
    y = tok_at(toks, k + 1)
    if not is_punct(tok_at(toks, k), '&') or y is None or y.kind != 'id' or y.text != x.text:
        return False
    k += 2
    if paren:
        if not is_punct(tok_at(toks, k), ')'):
            return False
        k += 1
    return is_punct(tok_at(toks, k), ')')


def int3_statement_end(toks, i):
    """If toks[i] starts `__asm__ [volatile] ("int $3\\n" : :);`, return the index just past its `;`, else None."""
    j = i + 1
    if tok_at(toks, j) is not None and toks[j].kind == 'id' and toks[j].text in ('volatile', '__volatile__', '__volatile'):
        j += 1
    s = tok_at(toks, j + 1)
    if not is_punct(tok_at(toks, j), '(') or s is None or s.kind != 'str' or decode_str(s.text) not in INT3_TEXT:
        return None
    if all(is_punct(tok_at(toks, j + 2 + k), p) for k, p in enumerate([':', ':', ')', ';'])):
        return j + 6
    return None


def weak_function_names(toks):
    """Names of functions declared or defined with __attribute__((__weak__)), as weak-symbols.py finds them."""
    names = set()
    for i, t in enumerate(toks):
        if t.kind != 'id' or t.text != '__attribute__' or not is_punct(tok_at(toks, i + 1), '('):
            continue
        end = match_fwd(toks, i + 1, '(', ')') + 1
        if not any(toks[k].kind == 'id' and toks[k].text == '__weak__' for k in range(i, end)):
            continue
        # The first identifier followed by '(' after the attribute, before the declaration ends.
        k = end
        while k < len(toks) and not (is_punct(toks[k], ';') or is_punct(toks[k], '{') or is_punct(toks[k], '}')):
            if toks[k].kind == 'id' and toks[k].text == '__attribute__' and is_punct(tok_at(toks, k + 1), '('):
                k = match_fwd(toks, k + 1, '(', ')') + 1
                continue
            if toks[k].kind == 'id' and is_punct(tok_at(toks, k + 1), '('):
                names.add(toks[k].text)
                break
            k += 1
    return names


def main():
    src_path, out_path, tail_path = sys.argv[1:4]
    src = open(src_path).read()
    toks = tokenize(src)
    edits = []  # (start, end, replacement)
    tail = []   # assembly directives, in source order
    weak = weak_function_names(toks)
    weak_marked = set()
    ctors = []  # constructor functions, in source order
    need_float = set()
    need_int3 = False
    prelude = {}  # name -> C declaration or definition that the rewritten code uses; prepended to the file
    if C_INPUT:
        keep = volatile_locals(toks)
        if keep:
            edits.extend(keep)
            prelude[KEEP_NAME] = KEEP_DEF

    def mark_weak_alias(name):
        # _ZTHx is the thread_local init alias for _ZTWx; if the wrapper is COMDAT (weak), so is the alias.
        if name.startswith('_ZTH') and '_ZTW' + name[4:] in weak and name not in weak_marked:
            weak_marked.add(name)
            tail.append(f'\t.weak {name}')

    i = 0
    while i < len(toks):
        t = toks[i]
        prev = tok_at(toks, i - 1)
        stmt_ctx = prev is None or (prev.kind == 'punct' and prev.text in (';', '}', '{'))

        # 0b. Hand-written C only (NFCXX_C_INPUT, set by nfcxx for .c inputs): cproc rejects every store to a
        # volatile object ("volatile store is not yet supported"), yet it already emits volatile loads as
        # plain loads and QBE does not reorder or remove memory accesses of an object whose address escapes
        # (struct members, globals). So the qualifier is dropped, except on inline asm. A volatile local
        # whose address is never taken is promoted to a register by QBE, so volatile_locals() makes its address escape.
        if C_INPUT and t.kind == 'id' and t.text in ('volatile', '__volatile__', '__volatile') and not (
                prev is not None and prev.kind == 'id' and prev.text in ('__asm__', '__asm', 'asm')):
            edits.append((t.start, t.end, ''))
            i += 1
            continue

        # 0a. glibc's <bits/floatn.h> (hand-written C, no __GNUC__) typedefs `float _Float32;`,
        # `long double _Float64x;` and the like. The names are mapped below (or have no cproc
        # equivalent), so the plain typedef of one of them is dropped; a use of an unmapped one is an error.
        if t.kind == 'id' and t.text == 'typedef':
            j = i + 1
            while j < len(toks) and not (toks[j].kind == 'punct' and toks[j].text in (';', '{', '(', '[')):
                j += 1
            if (j < len(toks) and toks[j].text == ';' and toks[j - 1].kind == 'id'
                    and toks[j - 1].text in DROP_TYPEDEF):
                edits.append((t.start, toks[j].end, ''))
                i = j + 1
                continue

        # 0. __attribute__((__constructor__)) on a function declaration: remove it, and list the function.
        if t.kind == 'id' and t.text == '__attribute__':
            # Exactly __attribute__((__constructor__)), after a parameter list: NAME ( params ) __attribute__(...)
            if (is_punct(tok_at(toks, i + 1), '(') and is_punct(tok_at(toks, i + 2), '(')
                    and tok_at(toks, i + 3) is not None and tok_at(toks, i + 3).text == '__constructor__'
                    and is_punct(tok_at(toks, i + 4), ')') and is_punct(tok_at(toks, i + 5), ')')
                    and is_punct(prev, ')')):
                lp = match_back(toks, i - 1, '(', ')')
                name = tok_at(toks, lp - 1) if lp > 0 else None
                if name is None or name.kind != 'id':
                    sys.exit('qbe-prep: cannot find the name of a constructor declaration')
                if name.text not in ctors:
                    ctors.append(name.text)
                edits.append((t.start, toks[i + 5].end, ''))
                i += 6
                continue

        # 1a. __asm__ volatile("int $3\n" : :); (doctest's debugger break): a call to the int3 stub.
        if t.kind == 'id' and t.text in ('__asm__', '__asm') and stmt_ctx:
            end = int3_statement_end(toks, i)
            if end is not None:
                edits.append((t.start, toks[end - 1].end, '__nfcxx_int3();'))
                need_int3 = True
                i = end
                continue

        # 1. __asm__("...") statements.
        if t.kind == 'id' and t.text in ('__asm__', '__asm') and is_punct(tok_at(toks, i + 1), '(') and stmt_ctx:
            j = i + 2
            strs = []
            while j < len(toks) and toks[j].kind == 'str':
                strs.append(decode_str(toks[j].text))
                j += 1
            if strs and is_punct(tok_at(toks, j), ')') and is_punct(tok_at(toks, j + 1), ';'):
                text = ''.join(strs).strip()
                stmt_start, stmt_end = t.start, toks[j + 1].end
                if re.fullmatch(r'\.align\s+\d+', text):
                    edits.append((stmt_start, stmt_end, ''))
                    i = j + 2
                    continue
                if t.depth == 0 and t.pdepth == 0:
                    m = re.fullmatch(r'\.(?:global|globl)\s+([A-Za-z_.$][\w.$]*)', text)
                    s = re.fullmatch(r'([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)', text)
                    if m:
                        tail.append(f'\t.globl {m.group(1)}')
                        mark_weak_alias(m.group(1))
                    elif s:
                        tail.append(f'\t.set {s.group(1)}, {s.group(2)}')
                        mark_weak_alias(s.group(1))
                    else:
                        sys.exit(f'qbe-prep: unsupported top-level asm "{text}"')
                    edits.append((stmt_start, stmt_end, ''))
                    i = j + 2
                    continue

        # 2. __attribute__((__aligned__(N))) after an array declarator: move it after the name.
        if t.kind == 'id' and t.text != '__attribute__' and is_punct(tok_at(toks, i + 1), '['):
            j = i + 1
            while j < len(toks) and is_punct(toks[j], '['):
                j = match_fwd(toks, j, '[', ']')
                if j < 0:
                    break
                j += 1
            g = aligned_group(toks, j) if 0 < j < len(toks) else None
            if g is not None:
                end, n = g
                edits.append((toks[j].start, toks[end - 1].end, ''))
                edits.append((t.end, t.end, f' __attribute__((__aligned__({n})))'))
                i = end
                continue

        # 3. struct T { char b[L]; } __attribute__((__aligned__(N)));
        if is_punct(t, '}'):
            g = aligned_group(toks, i + 1)
            if g is not None and is_punct(tok_at(toks, g[0]), ';'):
                end, n = g
                o = match_back(toks, i, '{', '}')
                body = [x.text for x in toks[o + 1:i]]
                if (len(body) == 6 and body[0] == 'char' and toks[o + 2].kind == 'id' and body[2] == '['
                        and toks[o + 4].kind == 'num' and body[4] == ']' and body[5] == ';'
                        and int(toks[o + 4].text, 0) % n == 0):
                    edits.append((toks[o].end, toks[o].end, f' _Alignas({n})'))
                    edits.append((toks[i + 1].start, toks[end - 1].end, ''))
                    i = end
                    continue

        # 4. Floating literals of the types above: f32/f64 drop the suffix; f16/f128 in parentheses become
        # the bit pattern as a brace initializer.
        if t.kind == 'num' and FLOAT_LIT.fullmatch(t.text):
            body, suffix = FLOAT_LIT.fullmatch(t.text).groups()
            paren = is_punct(prev, '(') and is_punct(tok_at(toks, i + 1), ')')
            if suffix == 'f32':
                edits.append((t.start, t.end, body + 'f'))
            elif suffix == 'f64':
                edits.append((t.start, t.end, body))
            elif suffix == 'f16' and paren:
                edits.append((prev.start, toks[i + 1].end, '{ 0x%04x }' % ieee_bits(body, 10, 5)))
                i += 2
                continue
            elif suffix == 'f128' and paren:
                bits = ieee_bits(body, 112, 15)
                edits.append((prev.start, toks[i + 1].end,
                              '{ { 0x%016xUL, 0x%016xUL } }' % (bits & (2 ** 64 - 1), bits >> 64)))
                i += 2
                continue
            else:
                sys.exit(f'qbe-prep: float literal {t.text} is not in a supported form')
            i += 1
            continue

        # 4c. (double)LITERALL: see the module docstring.
        if (C_INPUT and t.kind == 'num' and re.fullmatch(r'(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?[lL]', t.text)
                and re.search(r'[.eE]', t.text)
                and is_punct(tok_at(toks, i - 3), '(') and tok_at(toks, i - 2) is not None
                and tok_at(toks, i - 2).text in ('double', 'float') and is_punct(tok_at(toks, i - 1), ')')):
            edits.append((t.end - 1, t.end, ''))
            i += 1
            continue

        # 4a. alloca (hand-written C): a call, not the declaration `void *alloca (size_t)`, is cproc's builtin.
        if C_INPUT and t.kind == 'id' and t.text == 'alloca' and is_punct(tok_at(toks, i + 1), '(') and not is_punct(prev, '*'):
            edits.append((t.start, t.end, '__builtin_alloca'))
            i += 1
            continue

        # 4b. Builtins cproc lacks (see the module docstring).
        if t.kind == 'id' and t.text in LIBC_BUILTINS:
            name, proto = LIBC_BUILTINS[t.text]
            edits.append((t.start, t.end, name))
            prelude[name] = proto
        elif t.kind == 'id' and t.text in HELPER_BUILTINS:
            name, definition = HELPER_BUILTINS[t.text]
            edits.append((t.start, t.end, name))
            prelude[name] = definition
        elif t.kind == 'id' and t.text == '__builtin_mul_overflow' and mulov_const_shape(toks, i + 1):
            edits.append((t.start, t.end, MULOV_NAME))
            prelude[MULOV_NAME] = MULOV_DEF
        elif t.kind == 'id' and t.text in OV_OPS and is_punct(tok_at(toks, i + 1), '('):
            ranges, rp = split_args(toks, i + 1)
            if ranges is None or len(ranges) != 3:
                sys.exit(f'qbe-prep: {t.text} expects three arguments')
            text = [src[toks[a].start:toks[b - 1].end] for a, b in ranges]
            edits.append((t.start, toks[rp].end, overflow_call(OV_OPS[t.text], text, prelude)))
            i = rp + 1
            continue
        elif t.kind == 'id' and ATOMIC_RE.fullmatch(t.text):
            prelude[t.text] = atomic_prototype(t.text)

        # 5. Floating types cproc lacks.
        if t.kind == 'id' and t.text in FLOAT_TYPE:
            edits.append((t.start, t.end, FLOAT_TYPE[t.text]))
            need_float.add(FLOAT_TYPE[t.text])
        i += 1

    decls = [FLOAT_DECL[n] for n in ('struct __nfcxx_half16', 'struct __nfcxx_float128') if n in need_float]
    if need_int3:
        prelude['__nfcxx_int3'] = 'void __nfcxx_int3(void);'
        tail.append(INT3_STUB)
    decls += prelude.values()
    if decls:
        edits.append((0, 0, '\n'.join(decls) + '\n'))
    if ctors:
        tail.append('\t.pushsection .init_array,"aw"')
        tail.append('\t.p2align 3')
        tail.extend(f'\t.quad {name}' for name in ctors)
        tail.append('\t.popsection')

    # Apply edits from the end so earlier offsets stay valid.
    out = src
    for start, end, repl in sorted(edits, key=lambda e: (e[0], e[1]), reverse=True):
        out = out[:start] + repl + out[end:]
    open(out_path, 'w').write(out)
    open(tail_path, 'w').write('\n'.join(tail) + ('\n' if tail else ''))


if __name__ == '__main__':
    main()
