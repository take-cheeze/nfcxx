struct Point {
  var x: Int
  let label: Bool
}
struct Rect {
  var origin: Point
  var w: Int
}
var r = Rect(origin: Point(x: 1, label: true), w: 5)
r.origin.x = 9
print(r.origin.x)
print(r.w)
print(r.origin.label)
