class Counter:
    def __init__(self, start):
        self.n = start

    def bump(self, k):
        self.n = self.n + k
        return self.n

c = Counter(3)
c.bump(2)
result = c.bump(4)
