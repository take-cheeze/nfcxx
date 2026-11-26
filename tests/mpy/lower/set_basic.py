s = {1, 2, 3}
t = {'x', 'yy', 'zzz', 'w'}
u = {10, 20, 30, 40, 50}
e = {x for x in range(0)}
result = (s, len(s), 2 in s, 5 in s, len({1, 1, 1}), t, len(t), 'yy' in t, 'q' in t, u, e, len(e), (not not e), (not not s), 0 in {0})
