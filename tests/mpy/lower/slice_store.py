xs = [1, 2, 3, 4, 5]
xs[1:3] = [9]
xs[-1:] = [7, 8]
xs[10:12] = [0]
xs[2:2] = [5, 5]
del xs[1:3]
del xs[-1:]
ys = [1, 2]
ys[0:2] = ys
zs = [1, 2, 3, 4, 5]
zs[1:4] = zs
result = (xs, ys, zs)
