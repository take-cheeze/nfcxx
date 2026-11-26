# Keyword-only parameters (with and without defaults) and *args: the arguments are matched as the reference matches them, and
# their errors are the reference's. A closure over a keyword-only parameter and over *args sees the same values.
def f(a, *, b, c=3):
    return (a, b, c)

def g(x, y=2, *, k=5):
    return x + y * 10 + k * 100

def h(*args):
    return args

def m(a, *rest, k=1):
    return (a, rest, k)

def outer(n):
    def inner(x, *ys, z=1):
        return (x, ys, z, n)
    return inner

def cellk(*, p):
    def get():
        return p
    return get()

def cellr(*rs):
    def get():
        return rs
    return get()

def errs():
    out = []
    try:
        f(1)
    except TypeError as ex:
        out.append(str(ex))
    try:
        f(1, 2, b=3)
    except TypeError as ex:
        out.append(str(ex))
    try:
        f(1, b=2, z=3)
    except TypeError as ex:
        out.append(str(ex))
    try:
        f(1, a=0, b=2)
    except TypeError as ex:
        out.append(str(ex))
    try:
        h(k=1)
    except TypeError as ex:
        out.append(str(ex))
    try:
        g(1, 2, 3)
    except TypeError as ex:
        out.append(str(ex))
    return out

out = []
out.append(f(1, b=2))
out.append(f(1, c=7, b=2))
out.append(g(1))
out.append(g(1, 3, k=2))
out.append(h())
out.append(h(1, 'x', 3))
out.append(m(1))
out.append(m(1, 2, 3, k=4))
out.append(outer(4)(1, 2, z=3))
out.append(outer(4)(1))
out.append(cellk(p=9))
out.append(cellr(1, 2))

result = (out, errs())
