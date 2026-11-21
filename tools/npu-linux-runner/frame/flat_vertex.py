"""Flatten npu-render's nr_native_vs dispatch tree the same way as nr_native_row (see flat_dispatch.py).

nr_native_vs is an if-tree on `native` (conditions `native < K` / `native >= 38u`, with `else` branches) whose leaves
return one stage function. The NPU build of that tree has the same wrong-argument fault as the row tree, which
broke every native from 13 up. This pass evaluates the tree for each native id (the leaves are the only way the
function returns, so the mapping is exact) and emits a flat chain `if (native == n) return stage(st, sh);`.

usage: flat_vertex.py <in.c> <out.c>
"""
import re
import sys

HEAD = "NR_NOINLINE nr_i32 nr_native_vs(nr_u32 native, const nr_command_state *st, nr_shade *sh) {"
COND = re.compile(r"if \(native (<|>=) (\d+)u\)")
LEAF = re.compile(r"return (nr_stage_\w+)\(st, sh\);")


def tree_leaves(body):
    """Return [(path, callee)], path a list of (op, k) predicates that must all hold for the leaf."""
    stack = []          # per open block: the predicate for its 'then' branch, or its negation for 'else'
    tail = []           # negations of earlier one-line guards: they hold for everything after them
    leaves = []
    lines = body.splitlines()[1:]
    for line in lines:
        s = line.strip()
        m = COND.search(s)
        if m and s.endswith("{"):
            stack.append((m.group(1), int(m.group(2))))
            continue
        if s == "} else {":
            op, k = stack.pop()
            stack.append(("not", (op, k)))
            continue
        if s == "}":
            if stack:              # the function's own closing brace has no open block
                stack.pop()
            continue
        m1 = COND.search(s)
        if m1 and "return" in s:           # one-line guard: if (native >= 38u) return ...;
            callee = re.search(r"return (nr_\w+)\(st, sh\);", s).group(1)
            guard = (m1.group(1), int(m1.group(2)))
            leaves.append(([guard], callee))
            # later lines run only if the guard failed
            tail.append(("not", guard))
            continue
        leaf = LEAF.search(s)
        if leaf:
            leaves.append((list(stack) + list(tail), leaf.group(1)))
            continue
    return leaves


def holds(path, native):
    for item in path:
        if item[0] == "not":
            op, k = item[1]
            if (native < k) if op == "<" else (native >= k):
                return False
        else:
            op, k = item
            if not ((native < k) if op == "<" else (native >= k)):
                return False
    return True


def evaluate(leaves, native):
    hits = [callee for path, callee in leaves if holds(path, native)]
    if len(hits) != 1:
        raise SystemExit(f"native {native}: {len(hits)} leaves match (tree is not exclusive)")
    return hits[0]


def flatten_vertex(src, count=76):
    start = src.index(HEAD)
    end = src.index("\n}\n", start) + 3
    leaves = tree_leaves(src[start:end])
    lines = [HEAD]
    for n in range(count):
        lines.append(f"    if (native == {n}u) return {evaluate(leaves, n)}(st, sh);")
    lines.append("    return 0;\n}\n")
    return src[:start] + "\n".join(lines) + src[end:]


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        text = f.read()
    with open(sys.argv[2], "w") as f:
        f.write(flatten_vertex(text))
