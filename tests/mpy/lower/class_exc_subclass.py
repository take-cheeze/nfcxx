class MyError(ValueError):
    pass

def f():
    raise MyError("custom")

try:
    f()
except ValueError as e:
    result = "caught " + str(e)
