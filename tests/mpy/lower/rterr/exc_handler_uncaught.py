def g(x):
    try:
        return 10 // x
    except ZeroDivisionError:
        raise IndexError("in handler")

result = g(0)
