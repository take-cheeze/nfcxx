final class Tag {
  let id: Int
  init(id: Int) { self.id = id }
  deinit { print(id) }
}
struct Holder {
  var f: () -> Int
}
struct Outer {
  var h: Holder
  var extra: Int
}
enum Carrier {
  case val((Int) -> Int)
  case empty
}
struct Host {
  var f: (Int) -> Int
}
struct Point {
  var x: Int
  var y: Int
}
func first<T>(_ a: T, _ b: T, _ pick: (T) -> Bool) -> T {
  if pick(a) { return a }
  return b
}
func scope1() {
  let t = Tag(id: 10)
  let h = Holder(f: { t.id + 1 })
  print(h.f())
}
scope1()
print(1)
func scope2() {
  let t = Tag(id: 20)
  let outer = Outer(h: Holder(f: { t.id + 2 }), extra: 5)
  print(outer.h.f() + outer.extra)
}
scope2()
print(2)
func scope3() {
  let t = Tag(id: 30)
  let c = Carrier.val({ $0 + t.id })
  switch c {
  case .val(let f): print(f(1))
  case .empty: print(0)
  }
}
scope3()
print(3)
func scope4() {
  let t = Tag(id: 40)
  let host = Host(f: { $0 * t.id })
  print(host.f(2))
}
scope4()
print(4)
func movePoint() -> Int {
  var p = Point(x: 1, y: 2)
  let bump: () -> Void = { p.x = p.x + 10 }
  bump()
  bump()
  return p.x * 100 + p.y
}
print(movePoint())
let limit = 3
let big = first(5, 9, { $0 > limit })
print(big)
let small = first(1, 2, { $0 > limit })
print(small)
var base = 1000
let read: () -> Int = { base }
base = base + 1
print(read())
