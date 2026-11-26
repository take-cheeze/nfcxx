d = {'a': 1, 2: 'two', None: 3}
d[True] = 'yes'
d[1] = 'uno'
d['b'] = [1, 'x']
d[''] = None
result = (d, len(d), d['a'], d[2], d[None], d[''], 1 in d, 'b' in d, 'z' in d, None in d, 0 in d, len({}))
