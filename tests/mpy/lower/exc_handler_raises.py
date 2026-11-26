def f():
    try:
        try:
            raise ValueError("first")
        except ValueError:
            raise IndexError("second")
    except IndexError as e:
        return str(e)

result = f()
