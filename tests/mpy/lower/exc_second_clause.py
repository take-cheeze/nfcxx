def f(k):
    try:
        if k == 0:
            raise ValueError("v")
        if k == 1:
            raise IndexError("i")
        return "none"
    except ValueError:
        return "value"
    except IndexError as e:
        return "index " + str(e)

result = f(1)
