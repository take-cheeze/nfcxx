# super().name reads a class attribute of a base (LOAD_ATTR on the super object, not a call).
class A:
    scale = 3

class B(A):
    def get(self):
        return super().scale * 2

result = B().get()
