try:
    raise ValueError("a")
except ValueError as e:
    raise KeyError("b") from e
