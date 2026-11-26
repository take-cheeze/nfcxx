a = [1]
b = a
c = [1]
x = None
result = (x is None, x is not None, True is True, 1 is 1, 1 is True, 0 is False,
          a is b, a is c, a is not c, 'ab' is 'ab')
