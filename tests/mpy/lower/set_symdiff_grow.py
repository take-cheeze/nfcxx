# A set that grows during a symmetric difference (the table is rehashed when no slot is free), and removals that leave
# sentinels: pop then takes the first item left in table order, and a later insert reuses a freed slot.
s = {1, 2, 3, 4, 5, 6, 7, 8}
s ^= {2, 4, 6, 8, 10, 12, 14, 16, 18}
t = s ^ {1, 3, 20, 21, 22, 23}
p = t.pop()
q = t.pop()
u = {i for i in range(20)}
u.difference_update({3, 5, 7})
u.symmetric_difference_update({100, 3, 0})
t.add(40)
t.discard(10)
result = (s, t, p, q, u, len(u), 40 in t, 10 in t, 5 in u, 3 in u)
