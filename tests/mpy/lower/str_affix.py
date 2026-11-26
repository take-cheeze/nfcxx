# startswith and endswith: a str or a tuple of strs, with start and end bounds.
s = 'hello.py'
result = (s.startswith('he'), s.startswith('py'), s.endswith('.py'), s.endswith(('x', 'py')), s.startswith(('x', 'h')),
          s.startswith('l', 2), s.endswith('l', 0, 4), s.startswith(''), s.startswith('', 9), s.endswith('', 9),
          s.startswith('a', 9), 'abc'.startswith('', 4), 'abc'.endswith('c', -10, 3), 'abc'.startswith('a', 1, 0),
          'abc'.startswith(('x', 'ab'), 0), 'hello'.endswith('lo', 3))
