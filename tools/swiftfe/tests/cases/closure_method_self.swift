final class Scaler {
  let k: Int
  init(k: Int) { self.k = k }
  func scale() -> (Int) -> Int {
    return { $0 * self.k }
  }
  func scaleTwo() -> (Int) -> Int {
    return { $0 * self.k * 2 }
  }
}
func apply(_ f: (Int) -> Int, _ x: Int) -> Int {
  return f(x)
}
let s = Scaler(k: 3)
let f = s.scale()
print(f(4))
print(s.scaleTwo()(5))
print(apply({ $0 + 1 }, 9))
var acc = 0
for i in 0..<4 {
  let add: (Int) -> Void = { acc = acc + $0 + i }
  add(1)
}
print(acc)
func repeatIt(_ times: Int, _ body: (Int) -> Int) -> Int {
  var sum = 0
  var i = 0
  while i < times {
    sum = sum + body(i)
    i = i + 1
  }
  return sum
}
let offset = 100
print(repeatIt(3, { $0 + offset }))
