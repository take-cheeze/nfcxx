# remove takes the first equal item; index and count compare by equality, on a list and on a tuple, with start and end.
xs = [1, 2, 1, 3]
xs.remove(1)
ys = [1, 2, 1]
result = (xs, ys.index(1), ys.index(1, 1), ys.index(2, 0, 2), ys.count(1), ys.count(9), ys.index(1, -1),
          (4, 5, 4).index(4, 1), (4, 5, 4).count(4), [1, 'a', 1].count(1))
