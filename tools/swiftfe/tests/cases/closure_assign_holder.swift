final class Tag {
  let id: Int
  init(id: Int) { self.id = id }
  deinit { print(id) }
}
struct Holder {
  var f: (Int) -> Int
}
func scope1() {
  let t = Tag(id: 1)
  var h = Holder(f: { $0 + t.id })
  let set: () -> Void = { h = Holder(f: { $0 + 2 }) }
  print(h.f(10))
  set()
  print(h.f(10))
}
scope1()
print(5)
var cb: (Int) -> Int = { $0 }
let install: () -> Void = { cb = { $0 + 100 } }
print(cb(1))
install()
print(cb(1))
func scope2() {
  let t = Tag(id: 6)
  var cur: (Int) -> Int = { $0 }
  let swap: () -> Void = { cur = { $0 * t.id } }
  swap()
  print(cur(7))
  swap()
  print(cur(7))
}
scope2()
print(8)
