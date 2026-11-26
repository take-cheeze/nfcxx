# del of a cell variable unbinds it: a later store binds it again, and the closure sees the new value.
def outer(a):
    b = a
    def get():
        return b
    first = get()
    del b
    b = 7
    return (first, get(), b)

result = outer(3)
