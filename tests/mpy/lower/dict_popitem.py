# popitem removes the first item in table order, and returns it as a (key, value) tuple.
f = {1: 2, 3: 4}
a = f.popitem()
b = f.popitem()
result = (a, b, f, len(f))
