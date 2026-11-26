# str.center(width): the width counts characters, the left pad is half the padding (rounded down), and a str already that wide
# is the same object.
s = 'abc'
result = (
    'ab'.center(6),
    'ab'.center(7),
    'x'.center(4),
    s.center(2),
    s.center(2) is s,
    s.center(6),
    'é'.center(4),
    ''.center(3),
    'hi'.center(0),
)
