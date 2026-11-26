# A with block and a finally block are left in order, innermost first, through a break, a continue and a return: the exit runs
# when its block is left, and the finally body runs with it.
log = []

class Ctx:
    def __init__(self, name):
        self.name = name
    def __enter__(self):
        log.append('in ' + self.name)
        return self
    def __exit__(self, a, b, c):
        log.append('out ' + self.name)
        return False

def g1(xs):
    out = []
    for x in xs:
        with Ctx('w'):
            try:
                if x == 2:
                    break
                if x == 1:
                    continue
                out.append(x)
            finally:
                out.append(100 + x)
    return out

def g2():
    with Ctx('a'):
        try:
            with Ctx('b'):
                try:
                    return 'r'
                finally:
                    log.append('f-inner')
        finally:
            log.append('f-outer')

def g3():
    try:
        try:
            return 'x'
        finally:
            raise ValueError('boom')
    except ValueError:
        return 'caught'

def g4():
    r = []
    for i in range(4):
        try:
            try:
                if i == 1:
                    continue
                if i == 3:
                    break
                r.append(i)
            finally:
                r.append(-i)
        finally:
            r.append(i * 10)
    return r

def g5():
    x = 0
    try:
        x = 1
        return x
    finally:
        x = 2
        log.append(('x in finally', x))

def g6():
    for i in range(3):
        try:
            try:
                return i + 40
            finally:
                if i == 0:
                    log.append('g6 first')
        finally:
            log.append('g6 outer')
    return -1

a = g1([1, 2, 3])
b = g2()
c = g3()
d = g4()
e = g5()
f = g6()
result = (a, b, c, d, e, f, log)
