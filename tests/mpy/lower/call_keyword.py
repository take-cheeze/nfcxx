# Keyword arguments: each name matches its parameter, in a function, a method and a class's __init__.
def f(a, b, c=3):
    return (a, b, c)

class P:
    def __init__(self, x, y=2):
        self.x = x
        self.y = y
    def m(self, k=1):
        return self.x + self.y + k

p = P(1)
q = P(y=4, x=3)
result = (f(1, 2), f(1, c=5, b=2), f(b=9, a=8), f(7, 6, 5), p.x, p.y, q.x, q.y, p.m(), p.m(k=5), q.m(k=0))
