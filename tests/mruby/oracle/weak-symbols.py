#!/usr/bin/env python3
"""Emit `.weak` directives for functions that EDG marks __attribute__((__weak__)).

EDG puts COMDAT functions (inline and template instantiations) in every translation unit that
uses them, marked __weak__. GCC honours the attribute so the link merges the copies; cproc drops
attributes, so QBE emits them as strong symbols and the link fails with "multiple definition".
Usage: weak-symbols.py PREPROCESSED_C ASSEMBLY  (appends .weak lines to ASSEMBLY)
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


def weak_names(text):
    names = set()
    # Declarations and definitions are delimited by ; { } at top level.
    for chunk in re.split(r'[;{}]', text):
        if '__weak__' not in chunk:
            continue
        m = re.search(r'([A-Za-z_]\w*)\s*\(', strip_attributes(chunk))
        if m:
            names.add(m.group(1))
    return names


def main():
    c_path, asm_path = sys.argv[1:3]
    text = open(c_path).read()
    asm = open(asm_path).read()
    defined = set(re.findall(r'^([A-Za-z_.$][\w.$]*):', asm, re.M))
    weak = sorted(n for n in weak_names(text) if n in defined)
    if weak:
        with open(asm_path, 'a') as f:
            f.write('\n' + ''.join(f'.weak {n}\n' for n in weak))


if __name__ == '__main__':
    main()
