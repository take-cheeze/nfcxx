# Star unpacking (UNPACK_EX): the starred target is the list of the values between the others, and the other targets take the values
# before and after it. A generic iterable (a str, a range, a dict) is read once, and a nested target is unpacked as well.
a, *b = [1, 2, 3]
*c, d = (1, 2, 3)
e, *f, g = [1, 2, 3, 4]
h, *i, j = [1, 2]
k, *l = "xyz"
m, *n = range(4)
(o, *p), q = [1, 2], 3
r, *s, t = [7, 8, 9, 10, 11]
u, *v = {1: 'a', 3: 'b'}
result = (a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p, q, r, s, t, u, v)
