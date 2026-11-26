s = {(1, 2), 'a', 3, None}
e = {x for x in range(0)}
total = 0
for x in {4, 5, 6}:
    total += x
result = ((1, 2) in s, (2, 1) in s, 'a' in s, 3 in s, None in s, 7 in s, [1] in e, len(e), total, len({1, True, 0, False}))
