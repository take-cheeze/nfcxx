def outer(a):
    def inner(b, c=1):
        return a + b + c
    return inner(1, 2, 3)

result = outer(0)
