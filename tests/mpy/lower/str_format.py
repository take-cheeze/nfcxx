# str.format with empty, numbered and named fields (no format spec, no conversion): the values are formatted as str() gives them,
# the {{ and }} escapes are kept, and the errors are the reference's.
def errs(fn):
    try:
        fn()
    except Exception as e:
        return str(e)
    return 'no error'

result = (
    '{} and {}'.format(1, 'x'),
    '{0}{1}{0}'.format('a', 'b'),
    '{name}-{name}'.format(name=None),
    '{}'.format(True),
    '{{x}} {}'.format(5),
    '{a}{b}'.format(b=2, a='q'),
    '{} {}'.format(-3, 'e'),
    'plain'.format(),
    '{}{}'.format('', 7),
    '{a}'.format(a=1, b=2),
    errs(lambda: '{}'.format()),
    errs(lambda: '{0}{}'.format(1, 2)),
    errs(lambda: '{}{0}'.format(1, 2)),
    errs(lambda: '{x}'.format()),
    errs(lambda: '}'.format()),
    errs(lambda: '{'.format()),
    errs(lambda: '{5}'.format(1)),
)
