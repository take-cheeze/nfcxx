# str methods on a str receiver: case, strip, split and join, dispatched on the receiver at run time.
s = '  Hello, World  '
t = s.strip()
result = (t, t.upper(), t.lower(), s.lstrip(), s.rstrip(), 'xxhixx'.strip('x'), 'xxhixx'.lstrip('x'), 'ab!!'.rstrip('!'),
          'xyz'.strip('zx'), '  '.strip(), 'ABC'.lower(), ''.upper())
