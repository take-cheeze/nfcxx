def drain(seq):
    out = 0
    while len(seq) > 0:
        out = out * 10 + seq.pop()
    return out

xs = [3, 1]
xs.append(4)
xs.append(xs[0] * 10)
last = xs.pop()
first = xs.pop(0)
result = (last, first, xs, drain(xs), drain([7, 8]))
