# d.copy() has the table of d slot for slot (a deleted slot included); clear() empties the dict, which takes items again.
d = {1: 'a', 'x': 2, 3: 'c'}
del d[1]
e = d.copy()
e[9] = 'n'
d.clear()
d[5] = 6
result = (len(e), e.get(9), e, d, len(d))
