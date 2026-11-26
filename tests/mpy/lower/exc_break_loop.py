def find(xs, target):
    for i in range(len(xs)):
        try:
            if xs[i] == target:
                raise ValueError("found")
        except ValueError:
            return i
    return -1

total = 0
for i in range(10):
    try:
        if i == 4:
            break
        total = total + i
    except ValueError:
        total = 100

result = str(total) + " " + str(find([5, 6, 7], 6))
