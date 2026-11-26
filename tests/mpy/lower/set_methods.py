# The set methods: the tests issubset, issuperset and isdisjoint (any iterable is accepted), symmetric_difference (a new set),
# update and difference_update (any number of iterables), intersection_update and symmetric_difference_update (in place),
# and pop (the first item in table order, removed).
s = {1, 2, 3}
t = {2, 3, 4}
r1 = s.issubset({1, 2, 3, 4})
r2 = s.issuperset([1, 2])
r3 = s.isdisjoint([7, 8])
r4 = s.isdisjoint(t)
r5 = s.symmetric_difference(t)
r6 = s.symmetric_difference([3, 9])
s.update([10, 11], {12})
s.difference_update({1}, [2])
u = {5, 6}
u.intersection_update([6, 7, 5])
u.symmetric_difference_update({6, 9})
v = {1, 2}
v.update()
v.difference_update()
w = {1, 2, 3}
p = w.pop()
q = w.pop()
x = {4}
x.intersection_update({4})
result = (r1, r2, r3, r4, r5, r6, s, u, v, p, q, w, x, s.issubset([2, 3, 10, 11, 12, 99]), s.issuperset(s))
