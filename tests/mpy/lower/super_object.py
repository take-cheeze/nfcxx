# super() and super(cls, self) as objects: a method is looked up on them, as LOAD_METHOD does on any object.
class A:
    def f(self, x):
        return x * 10

class B(A):
    def f(self, x):
        s = super()
        return s.f(x) + 1

class C(B):
    def f(self, x):
        return super(C, self).f(x) + 2

result = [B().f(4), C().f(4)]
