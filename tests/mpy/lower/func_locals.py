def f(x):
    y = x * 2
    z = y + 1
    return z

def g(a):
    return f(a) + f(a + 1)

result = g(5)
