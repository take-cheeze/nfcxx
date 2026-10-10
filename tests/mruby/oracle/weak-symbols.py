#!/usr/bin/env python3
"""Emit `.weak` directives for functions and data objects that EDG marks __attribute__((__weak__)).

EDG puts COMDAT functions (inline and template instantiations) in every translation unit that
uses them, marked __weak__. GCC honours the attribute so the link merges the copies; cproc drops
attributes, so QBE emits them as strong symbols and the link fails with "multiple definition".
Usage: weak-symbols.py [--c-input] PREPROCESSED_C ASSEMBLY  (appends .weak lines to ASSEMBLY)
"""
import re
import sys


def strip_attributes(s):
    # Remove __attribute__((...)) groups, which may contain nested parentheses.
    out, i = [], 0
    while True:
        j = s.find('__attribute__', i)
        if j < 0:
            out.append(s[i:])
            return ''.join(out)
        out.append(s[i:j])
        k = j + len('__attribute__')
        while k < len(s) and s[k].isspace():
            k += 1
        depth = 0
        while k < len(s):
            if s[k] == '(':
                depth += 1
            elif s[k] == ')':
                depth -= 1
                if depth == 0:
                    k += 1
                    break
            k += 1
        i = k


def weak_names(text, extern_inline):
    names = set()
    # Declarations and definitions are delimited by ; { } at top level.
    for chunk in re.split(r'[;{}]', text):
        if '__weak__' in chunk:
            s = strip_attributes(chunk)
            s = s.split('=', 1)[0]
            m = re.search(r'([A-Za-z_]\w*)\s*\((?!\s*[*(])', s)
            if m:
                names.add(m.group(1))
            else:
                # COMDAT data: every identifier before the "=" is a candidate (the assembly decides).
                names.update(re.findall(r'[A-Za-z_]\w*', s))
        if extern_inline and '__inline__' in chunk and re.search(r'\bextern\b', chunk) \
                and not re.search(r'\bstatic\b', chunk):
            m = re.search(r'([A-Za-z_]\w*)\s*\((?!\s*[*(])', strip_attributes(chunk))
            if m:
                names.add(m.group(1))
    return names


def main():
    args = sys.argv[1:]
    extern_inline = True
    if args and args[0] == '--c-input':
        extern_inline = False
        args = args[1:]
    c_path, asm_path = args[:2]
    text = open(c_path).read()
    asm = open(asm_path).read()
    defined = set(re.findall(r'^([A-Za-z_.$][\w.$]*):', asm, re.M))
    weak = sorted(n for n in weak_names(text, extern_inline) if n in defined)
    if weak:
        with open(asm_path, 'a') as f:
            f.write('\n' + ''.join(f'.weak {n}\n' for n in weak))


if __name__ == '__main__':
    main()
