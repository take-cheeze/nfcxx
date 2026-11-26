# replace (with a count, and an empty old), find and count (with start and end, and clamped bounds).
result = ('aaa'.replace('a', 'bb', 2), 'abcabc'.replace('bc', 'X'), 'abc'.replace('', '-'), 'abc'.replace('', '-', 2),
          'x'.replace('y', 'z'), 'abc'.replace('b', 'X', -1), 'a'.replace('a', 'b', 0),
          'hello'.find('l'), 'hello'.find('l', 3), 'hello'.find('z'), 'hello'.find('', 2), 'hello'.find('h', -10),
          'hello'.find('l', 1, 3), 'hello'.find('', 9), 'abc'.find('', 4), 'abc'.find('c', -1), 'abc'.find('a', 1, 0),
          'aaaa'.count('aa'), 'abcabc'.count(''), 'abcabc'.count('b', 2), 'abc'.count('', 4), 'abc'.count('', -10),
          'abc'.count('a', 5, 9), 'ab'.count('a', -5))
