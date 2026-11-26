# split on a sep (with maxsplit) and on whitespace, and join over a list, a tuple and a str.
parts = 'a,b,,c'.split(',')
result = (parts, 'a,b,,c'.split(',', 1), ' a  b\tc '.split(), 'a  b c'.split(None, 1), '  a b  '.split(None, 0),
          ''.split(), 'a,'.split(','), 'aXbX'.split('X'), 'abc'.split(' ', -1), 'a-b'.split('-', 5),
          '-'.join(['x', 'y', 'z']), ''.join(('p', 'q')), 'ab'.join('xyz'), ''.join([]), ', '.join(['only']))
