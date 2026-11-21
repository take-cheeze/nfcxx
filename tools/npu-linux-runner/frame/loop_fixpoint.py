"""Stop a shader loop once it reaches a fixed point, keeping the output and the counters exact.

The emitted loops in npu-render's pixel rows are `for (;;)` with an iteration budget of 16 (nr_loop_guard). Each
iteration is a pure function of the locals it writes (the row's nr_v4 locals) and of inputs that do not change
inside the loop. If one iteration leaves every such local bit-for-bit unchanged and does not break, every later
iteration does exactly the same work: the same texture taps, the same escapes and no break. The remaining
iterations are therefore accounted for in closed form:

  escapes += delta * (16 - g)      (delta: escapes added by one iteration, g: the iteration that reached the fixed point)
  overflows += 1                   (the budget runs out at iteration 17, as in the original loop)

The transform leaves the loop text otherwise unchanged. It is applied to row functions only (their locals are the
loop state); the stage loops write through sh->out and are left alone.

usage: loop_fixpoint.py <in.c> <out.c>
"""
import re
import sys

LOOP_OPEN = "{ nr_u32 nr_loop_guard = 0; for (;;) {"


def function_span(src, head_re):
    m = re.search(head_re, src)
    if not m:
        return None
    i = m.end()
    depth = 1
    while depth:
        depth += {"{": 1, "}": -1}.get(src[i], 0)
        i += 1
    return m.start(), i


def state_names(fn_text):
    """Non-const nr_v4 locals declared before the first loop of the row function."""
    head = fn_text[: fn_text.find(LOOP_OPEN)]
    # function-level locals only: four-space indent (block-scoped temporaries are re-declared inside blocks)
    names = re.findall(r"^    nr_v4 (\w+) = ", head, flags=re.M)
    return list(dict.fromkeys(names))


def transform_row(fn_text):
    names = state_names(fn_text)
    if not names:
        return fn_text
    first = fn_text.find(LOOP_OPEN)
    if re.search(r"^    nr_v4 \w+ = ", fn_text[first:], flags=re.M):
        raise SystemExit("a row local is declared after its first loop; the snapshot would miss it")
    same = " && ".join(f"nr_v4_bits({n}, 0) == nr_v4_bits(nr_snap_{n}, 0) && nr_v4_bits({n}, 1) == nr_v4_bits(nr_snap_{n}, 1) && "
                       f"nr_v4_bits({n}, 2) == nr_v4_bits(nr_snap_{n}, 2) && nr_v4_bits({n}, 3) == nr_v4_bits(nr_snap_{n}, 3)"
                       for n in names)
    snaps = " ".join(f"nr_v4 nr_snap_{n} = {n};" for n in names)
    out = fn_text
    pos = 0
    while True:
        at = out.find(LOOP_OPEN, pos)
        if at < 0:
            break
        body_open = at + len(LOOP_OPEN)
        depth = 1
        j = body_open
        while depth:
            depth += {"{": 1, "}": -1}.get(out[j], 0)
            j += 1
        loop_body = out[body_open : j - 1].lstrip("\n")   # text inside `for (;;) {` ... `}`
        # the guard line is the first line of the loop body; the rest is the iteration body
        guard_line_end = loop_body.index("\n") + 1
        guard_line = loop_body[:guard_line_end]
        iteration = loop_body[guard_line_end:]
        if "row->overflows" not in guard_line:
            pos = j
            continue
        esc = "*row->escapes"
        new_iteration = (
            f"            nr_u32 nr_esc0 = {esc}; {snaps}\n"
            f"            {{\n{iteration}            }}\n"
            f"            if ({same}) {{ {esc} += ({esc} - nr_esc0) * (16u - nr_loop_guard); *row->overflows += 1u; break; }}\n"
        )
        replacement = LOOP_OPEN.replace("{ nr_u32", "{ nr_u32") + "\n" + guard_line + new_iteration + "        }"
        # keep the outer block that closes the loop: `for (;;) { ... }` is followed by ` }` in the source
        out = out[:at] + replacement + out[j:]
        pos = at + len(replacement)
    return out


def loop_fixpoint(src):
    span = function_span(src, r"NR_NOINLINE void nr_row_\d+\(const nr_row \*row\) \{")
    result = src
    offset = 0
    while True:
        m = re.compile(r"NR_NOINLINE void nr_row_\d+\(const nr_row \*row\) \{").search(result, offset)
        if not m:
            break
        start, end = function_span(result[m.start():], r"^NR_NOINLINE void nr_row_\d+\(const nr_row \*row\) \{")
        fn_text = result[m.start() : m.start() + end]
        new_fn = transform_row(fn_text)
        result = result[: m.start()] + new_fn + result[m.start() + end :]
        offset = m.start() + len(new_fn)
    return result


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        text = f.read()
    with open(sys.argv[2], "w") as f:
        f.write(loop_fixpoint(text))
