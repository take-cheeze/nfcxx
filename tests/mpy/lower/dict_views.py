d = {'x': 10, 'y': 20}
d['z'] = 30
ks = d.keys()
vs = d.values()
its = d.items()
keys = []
for k in d:
    keys.append(k)
total = 0
for v in d.values():
    total += v
pairs = []
for k, v in d.items():
    pairs.append(k + str(v))
result = (keys, total, pairs, ks, vs, its, len(ks), len(vs), len(its), 'x' in ks, 'x' in vs, 20 in vs, ('y', 20) in its,
          ('y', 21) in its, 'w' in ks, (not not ks), (not not {}.values()), {}.keys(), {}.items())
