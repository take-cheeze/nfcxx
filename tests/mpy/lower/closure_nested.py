def a(x):
    def b(y):
        def c(z):
            return x + y + z
        return c
    return b

result = a(1)(2)(3)
