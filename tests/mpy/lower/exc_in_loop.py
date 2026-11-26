out = 0
for i in range(5):
    try:
        if i % 2:
            raise ValueError("odd")
        out = out + 1
    except ValueError as e:
        out = out + 10
result = out
