def outer(x):
    def inner():
        return x
    return inner()

result = outer(1)
