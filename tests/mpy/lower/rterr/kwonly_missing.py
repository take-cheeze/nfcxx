# A keyword-only parameter without a default, and no keyword argument: the call fails at run time.
def k(a, *, b):
    return (a, b)

result = k(1)
