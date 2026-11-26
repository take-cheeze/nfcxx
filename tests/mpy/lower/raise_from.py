try:
    raise ValueError("a") from KeyError("b")
except ValueError as e:
    result = str(e)
