d = {'a': 1, 'b': 2}
got = (d.get('a'), d.get('z'), d.get('z', 9), d.get(2), d.get([1], 7))
p = d.pop('a')
q = d.pop('zz', 5)
d.update({'q': 7})
d.update([('r', 8), ['s', 9]])
d.update()
result = (got, p, q, d, len(d), d.get('s'), d.pop('r'), d)
