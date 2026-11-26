# bool is an int: arithmetic promotes, and `not` gives a bool
t = True
f = False
result = (t + t) * 3 - 1 + (f * 5) + (not f) + (not t) * 100
