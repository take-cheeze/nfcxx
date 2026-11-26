squares = {x * x for x in range(5)}
mods = {x % 3 for x in range(10)}
words = {s for s in ['ab', 'c', 'ab']}
result = (squares, mods, len(words), 'c' in words, [x for x in squares if x > 3])
