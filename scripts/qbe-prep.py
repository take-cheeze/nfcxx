#!/usr/bin/env python3
"""Rewrite EDG's preprocessed C so cproc accepts it, and emit the assembly the C cannot express.

cproc (the QBE front end) rejects a few GNU forms that EDG emits. This script tokenizes the
preprocessed C and rewrites only those forms; everything else passes through unchanged:

  * `__asm__(".align 2");` alignment hints (anywhere): dropped, as the old sed did. The hint
    only matters to EDG's own output, and it is not a semantic change.
  * Top-level `__asm__("...")` statements (not declarator labels) are removed from the C and
    re-emitted in the assembly tail: `.global X` / `.globl X` become `.globl X`, and `X = Y`
    becomes `.set X, Y`. EDG uses these for thread_local initialization aliases
    (`_ZTHx = __tls_init`). A `_ZTHx` alias is marked `.weak` when its `_ZTWx` wrapper is weak
    (COMDAT), as gcc does.
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

Usage: qbe-prep.py PREPROCESSED_C REWRITTEN_C ASM_TAIL
ASM_TAIL is appended to the QBE assembly by qbe-cc.
"""
import re
import sys
from fractions import Fraction

TOKEN_RE = re.compile(r'''
  (?P<ws>\s+)
| (?P<comment>//[^\n]*|/\*.*?\*/)
| (?P<str>(?:u8|[LuU])?"(?:[^"\\\n]|\\.)*")
| (?P<chr>(?:[LuU])?'(?:[^'\\\n]|\\.)*')
| (?P<num>\.?\d(?:[\w.]|[eEpP][+-])*)
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
    need_float = set()

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

        # 5. Floating types cproc lacks.
        if t.kind == 'id' and t.text in FLOAT_TYPE:
            edits.append((t.start, t.end, FLOAT_TYPE[t.text]))
            need_float.add(FLOAT_TYPE[t.text])
        i += 1

    decls = [FLOAT_DECL[n] for n in ('struct __nfcxx_half16', 'struct __nfcxx_float128') if n in need_float]
    if decls:
        edits.append((0, 0, '\n'.join(decls) + '\n'))

    # Apply edits from the end so earlier offsets stay valid.
    out = src
    for start, end, repl in sorted(edits, key=lambda e: (e[0], e[1]), reverse=True):
        out = out[:start] + repl + out[end:]
    open(out_path, 'w').write(out)
    open(tail_path, 'w').write('\n'.join(tail) + ('\n' if tail else ''))


if __name__ == '__main__':
    main()
