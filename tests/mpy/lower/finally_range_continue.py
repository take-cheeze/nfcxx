# A continue out of a finally body in a loop over a range: the finally's pending value is dropped, and the loop's increment runs
# on the counter. A break that swallows a pending exception (the finally's value is the exception) is the same.
log = []

def c1():
    out = []
    for i in range(4):
        try:
            out.append(i)
        finally:
            log.append(i)
            if i == 1:
                continue
        out.append(10 + i)
    return out

def c2():
    out = []
    for i in range(3):
        try:
            raise ValueError('x')
        finally:
            out.append(i)
            break
    return out

result = (c1(), c2(), log)
