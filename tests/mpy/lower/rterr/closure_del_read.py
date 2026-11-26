def outer():
    b = 5
    def inner():
        return b
    del b
    return inner()

result = outer()
