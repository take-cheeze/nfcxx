def f():
    try:
        return 1
    except ValueError:
        return 2

f()
raise KeyError('left')
