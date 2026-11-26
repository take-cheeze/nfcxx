# Positional defaults with *args, and keyword-only parameters in any order (a default before one without): the defaults fill
# the parameters the call leaves unset, and a missing keyword-only parameter without a default is the reference's error.
def p(a, b=2, *rest):
    return (a, b, rest)

def q(*, a=1, b):
    return (a, b)

def errs(fn):
    try:
        return fn()
    except TypeError as e:
        return str(e)

result = (
    p(1),
    p(1, 3),
    p(1, 3, 4, 5),
    q(b=2),
    q(a=5, b=6),
    errs(lambda: q()),
    errs(lambda: p()),
)
