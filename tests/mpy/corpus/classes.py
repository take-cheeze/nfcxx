class Point:
    def __init__(self, x, y=0):
        self.x = x
        self.y = y
    def norm(self):
        return self.x * self.x + self.y * self.y

p = Point(3, 4)
print(p.norm(), p.x, Point(1).y)
