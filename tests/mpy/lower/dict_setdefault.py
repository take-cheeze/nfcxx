# setdefault returns the value of a key that is there, and adds the key with a default (None when none is given) otherwise.
d = {'a': 1}
x = d.setdefault('a', 5)
y = d.setdefault('b')
z = d.setdefault('c', 7)
result = (x, y, z, d)
