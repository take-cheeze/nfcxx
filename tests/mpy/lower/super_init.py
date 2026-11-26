# super().__init__(...) chains a constructor through its bases, and reaches object's __init__ (which takes no argument).
class Base:
    def __init__(self, a):
        self.a = a
        self.log = [a]

class Mid(Base):
    def __init__(self, a, b):
        super().__init__(a)
        self.b = b
        self.log.append(b)

class Leaf(Mid):
    def __init__(self):
        super().__init__(1, 2)
        self.c = self.a + self.b

class Plain:
    def __init__(self):
        super().__init__()
        self.ok = True

l = Leaf()
result = (l.a, l.b, l.c, l.log, Plain().ok)
