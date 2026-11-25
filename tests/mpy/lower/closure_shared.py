def make():
    n = 10
    def inc():
        nonlocal n
        n += 1
        return n
    def get():
        return n
    global peek
    peek = get
    return inc

bump = make()
bump()
bump()
result = bump() * 100 + peek()
