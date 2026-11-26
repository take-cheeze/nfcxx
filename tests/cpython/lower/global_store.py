counter = 0

def bump(step):
    global counter
    counter = counter + step
    return counter

bump(3)
bump(4)
result = bump(10) * 2
