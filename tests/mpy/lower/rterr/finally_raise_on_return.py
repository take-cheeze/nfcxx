def f():
    try:
        return 1
    finally:
        raise ValueError('from the finally')

result = f()
