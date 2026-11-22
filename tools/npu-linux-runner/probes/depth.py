#!/usr/bin/env python3
"""Dependency depth of one pixel of an emitted npu-render row.

Takes the statements of the row's per-pixel loop body (in program order), finds the variables each reads and
writes, and computes the longest read-after-write chain. Write-after-write and write-after-read are ignored
(assumed renamed). Reports statements, critical-path length, and the ratio.

usage: depth.py frame_programs.h nr_row_14
"""
import re
import sys

KEYWORDS = {"if", "else", "for", "while", "return", "continue", "break", "sizeof", "const", "static",
            "void", "float", "int", "unsigned", "nr_u8", "nr_u32", "nr_i32", "nr_f32", "nr_v4", "nr_u16"}


def function_body(lines, name):
    start = next(i for i, l in enumerate(lines) if re.match(rf"NR_NOINLINE void {name}\(", l) or re.match(rf"void {name}\(", l))
    end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith("}"))
    return lines[start + 1:end]


def loop_body(body):
    """Return the lines inside the first `for (px` loop, from its header's opening brace to the matching close."""
    start = next(i for i, l in enumerate(body) if "for (px" in l)
    depth = 0
    out = []
    opened = False
    for l in body[start:]:
        for ch in l:
            if ch == "{":
                depth += 1
                opened = True
            elif ch == "}":
                depth -= 1
        if opened:
            out.append(l)
        if opened and depth == 0:
            break
    return out


def live_lines(lines):
    """Default build: macros undefined. Keep #ifndef bodies and #else bodies of #ifdef; drop the rest."""
    stack = []
    out = []
    for l in lines:
        s = l.strip()
        if s.startswith("#ifndef"):
            stack.append(True)
        elif s.startswith("#ifdef"):
            stack.append(False)
        elif s.startswith("#else"):
            stack[-1] = not stack[-1]
        elif s.startswith("#endif"):
            stack.pop()
        elif all(stack):
            out.append(l)
    return out


def statements(lines):
    """Split on ';' (ignoring comments). Returns list of statement strings."""
    text = []
    for l in live_lines(lines):
        s = l.strip()
        if s.startswith("//") or not s:
            continue
        text.append(re.sub(r"/\*.*?\*/", "", s))
    joined = " ".join(text)
    parts = [p.strip() for p in joined.split(";")]
    return [p for p in parts if p and p not in ("{", "}")]


IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def analyse(stmts):
    last_writer = {}
    depth = []
    tracked = set()
    deps_out = []
    for i, st in enumerate(stmts):
        # the assignment target: first identifier before a top-level '=' that is not '==' / '<=' / '>=' / '!='
        m = re.search(r"(?<![=!<>])=(?!=)", st)
        writes, reads = set(), set()
        if m:
            lhs, rhs = st[:m.start()], st[m.end():]
            lhs_ids = [x for x in IDENT.findall(lhs) if x not in KEYWORDS]
            if lhs_ids:
                writes.add(lhs_ids[-1])
            reads |= {x for x in IDENT.findall(rhs) if x not in KEYWORDS}
            if re.search(r"[+\-*/&|^]=|<<=|>>=", lhs):
                reads.add(lhs_ids[-1] if lhs_ids else "")
        else:
            reads |= {x for x in IDENT.findall(st) if x not in KEYWORDS}
        # NR_V4_SET(X, i, t): X is updated (read and written)
        for mm in re.finditer(r"NR_V4_SET\(\s*([A-Za-z_][A-Za-z0-9_]*)", st):
            writes.add(mm.group(1))
            reads.add(mm.group(1))
        if re.match(r"(if|for|while)\b", st):
            reads = {x for x in reads}
        # only track names that are program variables (written somewhere in the loop or declared)
        reads = {r for r in reads if r in tracked or r in last_writer}
        d = 1 + max((depth[last_writer[r]] for r in reads if r in last_writer), default=0)
        depth.append(d)
        for w in writes:
            last_writer[w] = i
            tracked.add(w)
        deps_out.append((i, sorted(reads), sorted(writes)))
    return depth, deps_out


def main():
    lines = open(sys.argv[1]).read().split("\n")
    body = function_body(lines, sys.argv[2])
    lp = loop_body(body)
    stmts = statements(lp)
    # two passes so loop-carried reads of values written earlier in the body are resolved
    depth, info = analyse(stmts)
    n = len(stmts)
    crit = max(depth) if depth else 0
    print(f"{sys.argv[2]}: statements in pixel body {n}, critical path {crit}, ratio {crit / n:.3f}")
    print(f"average depth-parallelism: {n / crit:.2f} statements per level")
    deepest = depth.index(crit) if crit else 0
    print("last statement on the critical path:", stmts[deepest][:120])


if __name__ == "__main__":
    main()
