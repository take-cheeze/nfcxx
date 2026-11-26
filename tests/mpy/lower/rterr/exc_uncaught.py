def f(k):
    if k:
        raise ValueError("bad " + "value")
    return 0

result = f(0)
result = f(1)
