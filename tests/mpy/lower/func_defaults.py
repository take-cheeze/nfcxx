# Default arguments: a missing argument takes its default from the tuple of defaults the function object holds.
def f(a, b=10, c=20):
    return a * 100 + b * 10 + c

def g(x, y=(1, 2), z='s'):
    return (x, y, z)

h = lambda x, k=2: x * k

result = (f(1), f(1, 2), f(1, 2, 3), f(1, c=5), f(1, 2, c=0), g(7), g(7, 'y'), h(3), h(3, 4))
