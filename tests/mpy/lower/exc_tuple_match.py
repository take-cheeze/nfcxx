def f(k):
    try:
        if k:
            raise KeyError("key")
        raise ValueError("val")
    except (KeyError, ValueError) as e:
        return str(e)

result = f(1) + " " + f(0)
