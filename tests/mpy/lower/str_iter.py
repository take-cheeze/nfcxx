out = []
for c in 'aé世!':
    out.append(c)
n = 0
for c in 'hello':
    if c == 'l':
        n += 1
pairs = []
for x in 'xy':
    for y in 'ab':
        pairs.append(x + y)
empty = []
for c in '':
    empty.append(c)
keys = {}.fromkeys('ba')
result = [out, n, pairs, empty, len(out), keys]
