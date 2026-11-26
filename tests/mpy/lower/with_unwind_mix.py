log = []

class Ctx:
    def __init__(self, name):
        self.name = name
    def __enter__(self):
        log.append('in ' + self.name)
        return self.name
    def __exit__(self, a, b, c):
        log.append('out ' + self.name)
        return False

def find(xs, target):
    for i in range(len(xs)):
        with Ctx('s'):
            try:
                if xs[i] == target:
                    return i
            except KeyError:
                log.append('key')
    return -1

def loop_try(n):
    total = 0
    for i in range(n):
        try:
            with Ctx('t'):
                if i == 2:
                    break
                if i == 0:
                    continue
                total = total + i
        except KeyError:
            total = 100
    return total

count = 0
while count < 10:
    count += 1
    with Ctx('w'):
        if count == 3:
            break
        if count == 1:
            continue
        log.append(count)

result = [log, find([4, 5, 6], 5), find([1], 9), loop_try(5), loop_try(1), count]
