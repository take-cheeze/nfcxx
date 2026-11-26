d = {}
for i in range(40):
    d[i] = i * i
for i in range(0, 40, 2):
    del d[i]
for i in range(0, 40, 4):
    d[i] = -i
result = (len(d), d[1], d[4], d[39], 2 in d, 4 in d, d[36], 38 in d)
