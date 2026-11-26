# A break out of a finally body in a range loop nested in an iterator loop, and in a try body: the outer loops go on, and the
# code after each loop runs at the depth it had before it.
def c3():
    out = []
    for x in [5, 6]:
        for i in range(3):
            try:
                out.append((x, i))
            finally:
                if i == 1:
                    break
        out.append(('after', x))
    for j in range(2):
        out.append(j)
    try:
        for k in range(3):
            try:
                out.append(k)
            finally:
                if k == 1:
                    break
        out.append('done')
    except ValueError:
        out.append('no')
    return out

result = c3()
