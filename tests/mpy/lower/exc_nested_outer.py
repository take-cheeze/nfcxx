def g():
    try:
        d = {'a': 1}
        return d['zz']
    except ValueError:
        return "wrong"

def f():
    try:
        return g()
    except KeyError as e:
        return "outer " + str(e)

result = f()
