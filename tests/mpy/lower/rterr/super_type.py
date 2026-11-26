# super(B, 3): 3 is not an instance of B, so the reference raises a TypeError with no text.
class A:
    def f(self):
        return 1

class B(A):
    def f(self):
        return super(B, 3).f()

result = B().f()
