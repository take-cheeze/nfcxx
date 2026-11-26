def label(value):
    return 1 if value is None else 2

x = None
result = label(x) * 10 + label(5) + (3 if x is not None else 4) * 100
