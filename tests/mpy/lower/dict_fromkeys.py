# dict.fromkeys(iterable[, value]) is a classmethod: called on a dict it makes a new dict, with None as the default value.
d = {}
a = d.fromkeys([1, 2])
b = d.fromkeys((3, 4, 5), 'v')
c = d.fromkeys(range(3), 0)
result = (a, b, c, d)
