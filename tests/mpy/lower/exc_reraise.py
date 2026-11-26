def g():
    try:
        raise TypeError("t")
    except TypeError:
        raise

try:
    g()
except TypeError as e:
    result = "outer " + str(e)
