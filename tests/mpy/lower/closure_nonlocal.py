def outer(x):
    def inner(y):
        nonlocal x
        x += y
        return x
    return inner

g = outer(10)
g(1)
result = g(5)
