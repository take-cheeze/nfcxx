log = []

class Ctx:
    def __init__(self, name):
        self.name = name
    def __enter__(self):
        log.append('enter ' + self.name)
        return self
    def __exit__(self, a, b, c):
        log.append('exit ' + self.name + ' ' + str(a))
        return False

class Quiet:
    def __enter__(self):
        return self
    def __exit__(self, a, b, c):
        log.append('quiet')
        return True

for i in range(5):
    with Ctx('a'):
        with Ctx('b'):
            if i == 1:
                continue
            if i == 3:
                break
            log.append(i)
    log.append('end ' + str(i))

def f(x):
    with Ctx('f'):
        with Quiet():
            if x:
                return 'early'
    return 'late'

def g():
    for j in range(3):
        with Ctx('g'):
            for k in range(3):
                with Quiet():
                    if k == 1:
                        break
            if j == 1:
                return j
    return -1

result = [log, f(1), f(0), g()]
