# del of a free variable (through nonlocal) unbinds the cell: a read of it afterwards is a NameError.
def outer():
    b = 1
    def inner():
        nonlocal b
        del b
    inner()
    try:
        return b
    except NameError:
        return 'unbound'

result = outer()
