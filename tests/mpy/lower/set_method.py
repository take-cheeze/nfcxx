# set.add, discard: an added item is in the set once, and discard of a missing item does nothing.
s = {1, 2}
s.add(3)
s.add(2)
s.discard(1)
s.discard(42)
result = (s, len(s), 2 in s, 1 in s)
