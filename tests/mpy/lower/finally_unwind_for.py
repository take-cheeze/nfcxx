# A break and a continue out of finally bodies in a loop over an iterator: the loop's iterator is dropped with the break, and a
# continue runs the finally and the loop goes on.
log = []

def h1(xs):
    out = []
    for x in xs:
        try:
            out.append(x)
        finally:
            log.append(x)
            if x == 1:
                break
    out.append('end')
    return out

def h6(xs):
    out = []
    for x in xs:
        try:
            try:
                if x == 0:
                    continue
                out.append(x)
            finally:
                out.append(-x)
                if x == 2:
                    break
        finally:
            out.append(x * 10)
    return out

a = h1([0, 1, 2])
b = h6([0, 1, 2, 3])
result = (a, b, log)
