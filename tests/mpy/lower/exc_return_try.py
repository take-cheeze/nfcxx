def f(x):
    try:
        if x:
            return "ret"
        raise ValueError("no")
    except ValueError as e:
        return "caught " + str(e)

def deep(n):
    if n == 0:
        raise IndexError("bottom")
    return deep(n - 1) + 1

def top():
    try:
        return deep(50)
    except IndexError as e:
        return str(e)

result = f(1) + ";" + f(0) + ";" + top()
