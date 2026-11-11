func make(_ k: Int) -> (Int) -> Int {
  return { $0 * k }
}
func counter() -> () -> Int {
  var n = 0
  return { n = n + 1; return n }
}
func adder(_ base: Int) -> (Int) -> (Int) -> Int {
  return { (a: Int) -> (Int) -> Int in
    return { (b: Int) -> Int in base + a + b }
  }
}
final class Box {
  var v: Int
  init(v: Int) { self.v = v }
  deinit { print(v) }
}
func useObj() -> (Int) -> Int {
  let o = Box(v: 7)
  return { $0 + o.v }
}
let f = make(3)
print(f(5))
var total = 0
let bump: () -> Void = { total = total + 10 }
bump()
bump()
print(total)
let c = counter()
print(c())
print(c())
let add = adder(100)(20)
print(add(3))
let g = useObj()
print(g(1))
var seen = 1
let peek: () -> Int = { seen }
seen = 42
print(peek())
struct Op {
  var f: (Int) -> Int
  var g: (Int) -> Int
}
let ops = Op(f: make(2), g: { $0 - 1 })
print(ops.f(10))
print(ops.g(10))
let h = make(4)
print(h(h(2)))
