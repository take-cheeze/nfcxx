def is_even(n):
    if n == 0:
        return True
    return is_odd(n - 1)

def is_odd(n):
    if n == 0:
        return False
    return is_even(n - 1)

def weigh(a, b, c):
    return a * 100 + b * 10 + c

result = weigh(is_even(10), is_odd(10), is_odd(7)) + weigh(1, 2, 3)
