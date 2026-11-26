class Base:
    def __init__(self, v):
        self.v = v

    def hi(self):
        return "base"

    def twice(self):
        return self.hi() + self.hi()

class Child(Base):
    def hi(self):
        return "child"

result = Base(1).twice() + " " + Child(4).twice() + " " + str(Child(4).v * 10)
