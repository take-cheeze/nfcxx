struct Point {
  var x: Int
  var y: Double
}

class Counter {
  var n: Int
}

var a = 10
a += 5
a -= 3
a *= 4
a /= 6
print(a)

var d = 1.5
d += 2.0
d *= 2.0
d -= 0.5
d /= 4.0
print(d)

var p = Point(x: 2, y: 1.0)
p.x += 3
p.x *= 2
p.y /= 4.0
print(p.x)
print(p.y)

let c = Counter(n: 1)
c.n += 4
c.n -= 7
print(c.n)
