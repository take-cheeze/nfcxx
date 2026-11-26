class Base:
    def hi(self):
        return 1

class Child(Base):
    def hi(self):
        return super().hi() + 1

result = Child().hi()
