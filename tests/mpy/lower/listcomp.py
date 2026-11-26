xs = [1, 2, 3, 4]
evens = [x * 10 for x in xs if x % 2 == 0]
grid = [[y for y in range(x)] for x in range(3)]
words = [s + '!' for s in ['a', 'bc']]
result = (evens, grid, words, [x for x in xs][1:3])
