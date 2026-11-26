K = 10

class A:
    x = 3
    y = x * 2

    def helper(self, v):
        return v * 2 + K

    def run(self, v):
        return self.helper(v) + 1

result = A().run(3) + A.x + A.y
