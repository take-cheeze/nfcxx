# The set operators | & - build new sets; their in-place forms |= &= -= change the left set.
s = {1, 2, 3}
t = {3, 4}
u = s | t
v = s & t
w = s - t
x = {1, 2}
x |= t
y = {1, 2, 3}
y &= t
z = {1, 2, 3}
z -= {2}
z -= z
result = (u, v, w, x, y, z, s)
