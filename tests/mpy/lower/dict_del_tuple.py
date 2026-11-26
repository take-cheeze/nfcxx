# del of a dict item whose key is a tuple: the tuple's hash and equality find the slot (its items compared by value, a str built at
# run time too), and a deleted slot is reused by a later store.
d = {(1, 2): 'a', (3, 4): 'b'}
del d[(3, 4)]
d[(5, 6)] = 'c'
del d[(5, 6)]
d[(7, 8)] = 'z'
k = ('a' + 'b', 1)
e = {('ab', 1): 2, (3, 'cd'): 4, (5, 6): 7}
del e[k]
del e[(3, 'c' + 'd')]
f = {(None, True): 1}
del f[(None, True)]
result = (len(d), (1, 2) in d, (3, 4) in d, (5, 6) in d, d[(7, 8)], d.get((1, 2)), len(e), k in e, (5, 6) in e, len(f))
