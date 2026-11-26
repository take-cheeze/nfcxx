def f(x):
    try:
        if x:
            raise ValueError("bad")
        r = 1
    except ValueError as e:
        r = str(e)
    except IndexError:
        r = 3
    return r

result = f(1)
