found = -1
for i in range(100):
    if i * i > 50:
        found = i
        break
    if i % 2 == 1:
        continue
result = found
