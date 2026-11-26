def first_square_over(limit):
    for i in range(1, 100, 3):
        if i * i > limit:
            return i
    return -1

result = (first_square_over(10), first_square_over(10000), len(range(3, 9, 2)))
