d = {'x': 1, 'y': 2, 3: 'c'}
del d['x']
d['x'] = 5
del d[3]
xs = [1, 2, 3, 4]
del xs[1]
del xs[-1]
result = (d, xs, 'x' in d, 3 in d)
