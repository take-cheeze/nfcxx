def count(seq):
    return len(seq)

xs = [1, 2, 3]
t = (4, 5)
s = 'héllo'
result = len(xs) + len(t) * 10 + len(s) * 100 + count(xs) * 1000 + len('') * 10000
