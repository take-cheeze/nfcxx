class A:
    pass

a = A()
a.x = 5
del a.x
try:
    a.x
    result = "still there"
except AttributeError as e:
    result = str(e)
