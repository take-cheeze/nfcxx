# A call's ** mapping argument: its items are keyword arguments, in the mapping's order, matched to the parameters and collected
# by **kwargs as the reference does. An empty mapping passes none, and mappings can follow keyword arguments or each other. A
# method and a class's __init__ take the same arguments.
def f(a, b=2, *, k=5, **kw):
    return (a, b, k, kw)

def e(fn):
    try:
        return fn()
    except TypeError as ex:
        return str(ex)

class C:
    def __init__(self, x, y=0, **kw):
        self.x = x
        self.y = y
        self.kw = kw

    def m(self, x, **kw):
        return (x, kw)

d = {'k': 7, 'z': 8}
o = C(1, **{'y': 2, 'w': 3})

result = (
    f(1, **d),
    f(1, **{}),
    f(**{'a': 3}),
    f(1, 2, **d),
    f(1, **d, **{'q': 9}),
    f(1, q=0, **{'b': 4}),
    e(lambda: f(1, b=2, **{'b': 3})),
    e(lambda: f(**{'a': 1}, a=2)),
    o.x,
    o.y,
    o.kw,
    o.m(5, **d),
    d,
)
