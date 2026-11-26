out = ""
try:
    raise ValueError(5)
except Exception as e:
    out = out + str(e) + "|"
try:
    x = 1 + "a"
except TypeError as e:
    out = out + "type|"
try:
    d = {}
    d[[1]] = 2
except TypeError as e:
    out = out + str(e) + "|"

class Box:
    def __init__(self, v):
        self.v = v

    def value_of(self):
        return self.v

boxes = [Box(1), Box(2)]
total = 0
for b in boxes:
    total = total + b.value_of()
result = out + str(total)
