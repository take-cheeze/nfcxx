def outer():
    total = 0
    def add(v):
        nonlocal total
        total += v
    add(3)
    add(4)
    return total

result = outer()
