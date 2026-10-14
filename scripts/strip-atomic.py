#!/usr/bin/env python3
# cproc has no _Atomic. Rewrites, in preprocessed C, _Atomic(T) to T (the qualifier only changes how the member is
# accessed, not its layout; the atomic operations are calls into libc++) and drops a bare _Atomic keyword. Balanced
# parentheses, so an argument that spans lines or nests parentheses is handled. Used on macOS by scripts/qbe-cc.
import re, sys

def strip(text):
    out, i = [], 0
    pat = re.compile(r'(?<![A-Za-z0-9_])_Atomic(?![A-Za-z0-9_])')
    while True:
        m = pat.search(text, i)
        if not m:
            out.append(text[i:]); break
        out.append(text[i:m.start()])
        j = m.end()
        k = j
        while k < len(text) and text[k] in ' \t\n':
            k += 1
        if k < len(text) and text[k] == '(':
            depth, e = 0, k
            while e < len(text):
                if text[e] == '(':
                    depth += 1
                elif text[e] == ')':
                    depth -= 1
                    if depth == 0:
                        break
                e += 1
            out.append(text[k + 1:e])   # the inner type, without the parentheses
            i = e + 1
        else:
            i = j                        # bare keyword: drop it
    return ''.join(out)

sys.stdout.write(strip(sys.stdin.read()))
