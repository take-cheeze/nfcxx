class Ctx:
    def __enter__(self):
        return self
    def __exit__(self, a, b, c):
        return False

for i in range(3):
    with Ctx():
        try:
            break
        finally:
            pass
result = i
