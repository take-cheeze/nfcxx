total = 0
for i in range(4):
    try:
        if i == 2:
            raise ValueError("skip")
        total = total + i
    except ValueError:
        continue
result = total
