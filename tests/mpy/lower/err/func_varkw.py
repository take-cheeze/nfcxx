# A **kwargs parameter: the keyword dict is not built yet, so the function is refused.
def f(a, **kw):
    return (a, kw)

result = f(1, b=2)
