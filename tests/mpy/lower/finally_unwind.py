# A return, a break and a continue run the finally bodies they leave, innermost first, as the VM's unwind does. A return out of a
# finally body (the site is in the handler) only drops that block. Nested finally blocks and a finally in a loop are covered.
log = []

def f1():
    try:
        return 1
    finally:
        log.append(1)

def f2():
    try:
        try:
            return 2
        finally:
            log.append(2)
    finally:
        log.append(3)

def f3(xs):
    for x in xs:
        try:
            if x == 2:
                break
            log.append(x)
        finally:
            log.append(10 + x)
    return 0

def f4():
    try:
        return 4
    finally:
        return 5

def f5():
    try:
        pass
    finally:
        log.append(50)
    return 6

a = f1()
b = f2()
c = f3([1, 2, 3])
d = f4()
e = f5()
result = (a, b, c, d, e, log)
