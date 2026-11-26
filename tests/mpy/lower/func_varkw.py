# A **kwargs parameter: the keyword arguments that no parameter takes go into a dict, which is empty when there are none. It is
# the last parameter, after *args and the keyword-only ones. Each call gets its own dict, and a closure's dict is its own too.
def f(a, **kw):
    return (a, kw)

def g(a, b=2, *, k=5, **kw):
    return (a, b, k, kw)

def h(*args, **kw):
    return (args, kw)

def m(a, *rest, k=1, **kw):
    return (a, rest, k, kw)

def outer(n):
    def inner(x, **kw):
        return (x, n, kw)
    return inner

def errs(fn):
    try:
        return fn()
    except TypeError as ex:
        return str(ex)

def add(**kw):
    kw['extra'] = 1
    return kw

result = (
    f(1),
    f(1, b=2, c=3),
    g(1),
    g(1, 3, z=4, k=0),
    h(),
    h(1, x=2),
    m(1),
    m(1, 2, 3, q=4, k=2),
    outer(4)(1, y=5),
    outer(4)(1),
    add(a=2),
    add(),
    errs(lambda: f()),
    errs(lambda: f(1, 2)),
    errs(lambda: f(1, a=2)),
)
