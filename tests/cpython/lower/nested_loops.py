count = 0
for i in range(1, 6):
    for j in range(i):
        if (i + j) % 3 == 0:
            continue
        count = count + i * j
result = count
