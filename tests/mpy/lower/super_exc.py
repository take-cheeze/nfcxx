# An exception class whose __init__ calls the builtin exception's __init__ with the message: str(e) is that message.
class Err(ValueError):
    def __init__(self, m, code):
        super().__init__(m)
        self.code = code

def go():
    try:
        raise Err("boom", 7)
    except ValueError as e:
        return str(e) + "/" + str(e.code)

result = go()
