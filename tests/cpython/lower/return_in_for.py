# return from inside a for loop: the iterator is popped under the return value
def first_square_over(limit):
    for i in range(100):
        if i * i > limit:
            return i
    return -1

result = first_square_over(50) * 100 + first_square_over(10000)
