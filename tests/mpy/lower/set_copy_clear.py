# set.copy makes a set of the same table, and set.clear empties the set it is called on.
s = {1, 2}
t = s.copy()
t.add(3)
u = {4, 5}
r = u.clear()
result = (s, t, len(t), r, u, len(u), {5, 1, 3, 2, 4}.copy())
