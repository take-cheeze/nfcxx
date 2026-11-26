def outer(a):
    def inner(b=1):
        return a + b
    return inner(2)

result = outer(3)
