# super().f(x) in three levels of a class chain: each method calls its base's method through the __class__ cell.
class A:
    def f(self, x):
        return x + 1

class B(A):
    def f(self, x):
        return super().f(x) * 2

class C(B):
    def f(self, x):
        return super().f(x) + 100

result = [C().f(3), B().f(3), A().f(3)]
