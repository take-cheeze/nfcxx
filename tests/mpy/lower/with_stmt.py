log = []

class Ctx:
    def __init__(self, name):
        self.name = name
    def __enter__(self):
        log.append('enter ' + self.name)
        return self.name + '!'
    def __exit__(self, a, b, c):
        log.append('exit ' + self.name)
        return False

class Quiet:
    def __enter__(self):
        return 7
    def __exit__(self, a, b, c):
        log.append('quiet')
        return True

with Ctx('a') as v:
    log.append(v)
with Quiet() as q:
    log.append(q)
    raise ValueError('inside')
log.append('after')
try:
    with Ctx('b'):
        raise KeyError('k')
except KeyError as e:
    log.append('caught ' + str(e))
result = log
