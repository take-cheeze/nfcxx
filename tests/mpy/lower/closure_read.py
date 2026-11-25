def outer(a):
    def inner(b):
        return a + b
    return inner(1)

result = outer(2)
