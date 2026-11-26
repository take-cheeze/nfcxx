# A continue out of a finally body in a loop over an iterator: the pending value is cancelled, and the iterator stays on the stack
# for the loop's next item (the target is the loop head, with the iterator below it).
def k(xs):
    out = []
    for x in xs:
        try:
            out.append(x)
        finally:
            if x == 1:
                continue
            out.append(-x)
        out.append(x * 10)
    return out

result = k([0, 1, 2, 3])
