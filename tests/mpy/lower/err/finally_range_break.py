# A break out of a finally body in a loop over a range: the reference leaves the finally's pending value on the stack at the loop's
# end, one deeper than the normal exit, so the lowering refuses it (no static depth holds both).
def f():
    out = []
    for i in range(4):
        try:
            out.append(i)
        finally:
            if i == 1:
                break
    return out

result = f()
