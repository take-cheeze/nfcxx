class Ctx:
    def __enter__(self):
        return self
    def __exit__(self, a, b, c):
        return False

with Ctx():
    raise ValueError('out')
result = 0
