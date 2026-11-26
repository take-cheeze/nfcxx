# reverse, and sort (ints, strs, reverse=True, and a key). The key sort is MicroPython's quicksort, which is not stable.
xs = [3, 1, 2]
xs.reverse()
ys = [3, 1, 2]
ys.sort()
zs = ['bb', 'a', 'ccc', '']
zs.sort()
ws = [3, 1, 2]
ws.sort(reverse=True)
vs = [3, 1, 2, 5, 4, 0]
vs.sort(key=lambda v: -v)
big = [5, 3, 9, 1, 7, 2, 8, 6, 4, 0, 11, 10]
big.sort()
ps = [(1, 'a'), (0, 'b'), (1, 'c'), (0, 'd'), (1, 'e')]
ps.sort(key=lambda p: p[0])
ks = [1, 2]
ks.sort(key=lambda v: 0)
result = (xs, ys, zs, ws, vs, big, ps, ks)
