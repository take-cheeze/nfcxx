def f(a, b=2):
    return a * b + a // 3 - a % 5 + (a << 2) + (b >> 1) + (a & 3) + (a | 1) + (a ^ 7) + ~a - -b

x = f(7) + f(3, 4)
print(x, x < 10, x >= 3, x == 5, x != 6, not x)
