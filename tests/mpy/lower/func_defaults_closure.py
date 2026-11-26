# A nested function with defaults is a closure with its defaults: the cell comes first, then the arguments and the defaults.
def outer(a):
    def inner(b=1, c=2):
        return a + b * 10 + c * 100
    return (inner(), inner(5), inner(c=3), inner(7, 8))

result = outer(4)
