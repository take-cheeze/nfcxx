def gcd(a, b):
    while b != 0:
        a, b = b, a % b
    return a

result = gcd(1071, 462) * 1000 + gcd(17, 5)
