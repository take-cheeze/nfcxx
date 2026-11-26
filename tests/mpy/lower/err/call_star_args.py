# A call that unpacks a *-argument (f(*xs, **d)): the bitmap of the starred positions is not 0, so the call is refused.
def f(*a, **kw):
    return (a, kw)

xs = (1, 2)
result = f(*xs, **{'k': 1})
