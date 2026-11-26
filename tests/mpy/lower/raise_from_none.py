def f(x):
    try:
        raise KeyError(x) from None
    except KeyError as e:
        return str(e)

result = [f(1), f('k')]
