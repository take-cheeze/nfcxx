class C:
    def __init__(self):
        self.n = 0

    def add(self, k):
        self.n = self.n + k
        return self.n

c = C()
f = c.add
f(5)
result = f(2)
