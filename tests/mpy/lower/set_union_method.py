# set.union, intersection and difference take any iterable (intersection and difference of several), and return new sets.
s = {1, 2, 3}
a = s.union([3, 4, 5])
b = s.intersection(range(2, 9))
c = s.difference([1], (3,))
d = s.difference()
e = {1, 2, 3, 4, 5, 6, 7, 8}.union([9, 10])
result = (a, b, c, d, e, s)
