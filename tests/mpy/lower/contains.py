words = ['ab', 'cd']
t = (1, 'x', None)
result = ('ab' in words, 'zz' not in words, 2 in t, 1 in t, True in t, 'x' in t, None in t,
          'ell' in 'hello', '' in 'hello', 'lo!' in 'hello', 'h' not in 'abc')
