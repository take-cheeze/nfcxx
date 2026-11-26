class Ctx:
    def __enter__(self):
        return self
    def __exit__(self, a, b, c):
        return False

def f():
    with Ctx():
        return 1

result = f()
