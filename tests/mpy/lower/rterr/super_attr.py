# super() has no attribute zz: the base has none, and the class itself is not searched.
class A:
    pass

class B(A):
    def g(self):
        return super().zz

result = B().g()
