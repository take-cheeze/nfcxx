# insert clamps its index as the reference does, and extend takes any iterable (a list is extended by itself too).
a = [1, 2, 3]
a.insert(1, 9)
a.insert(-1, 8)
a.insert(10, 7)
a.insert(-10, 0)
b = [1]
b.extend((2, 3))
b.extend('ab')
b.extend([4])
b.extend(b)
result = (a, b)
