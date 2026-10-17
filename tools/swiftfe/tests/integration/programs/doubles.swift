// Double arithmetic, comparison and printing, checked against Swift's own output.
struct Point {
  var x: Double
  var y: Double
}

func norm2(_ p: Point) -> Double {
  return p.x * p.x + p.y * p.y
}

func average(_ a: Double, _ b: Double) -> Double {
  return (a + b) / 2.0
}

print(100000.0)
print(1e15)
print(1e16)
print(123456.789)
print(0.0001)
print(0.00001)
print(1.0 / 3.0)
print(-0.0)
print(2.5)
print(1.0 / 0.0)
print(0.1 + 0.2)
print(Double(7) / 2.0)
print(average(3.0, 4.5))
print(norm2(Point(x: 3.0, y: 4.0)))
print(Point(x: 1.5, y: -2.25).y)
print(2.0 < 2.5)
print(2.0 == 2.0)
let zero: Double? = nil
let half: Double? = 0.5
print(zero == nil)
if let h = half {
  print(h * 4.0)
}
var acc = 0.0
var i = 0
while i < 10 {
  acc = acc + 0.1
  i = i + 1
}
print(acc)
