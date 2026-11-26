result = 0
try:
    raise KeyError("k")
except ValueError:
    result = 1
