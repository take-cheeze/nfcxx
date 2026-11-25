def check(v):
    try:
        if v:
            raise ValueError("bad")
        return 1
    except ValueError as e:
        return str(e)
    finally:
        pass

print(check(0), check(1))
with open("/dev/null") as fh:
    pass
