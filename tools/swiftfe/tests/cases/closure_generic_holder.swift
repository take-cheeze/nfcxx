final class Tag {
  let id: Int
  init(id: Int) { self.id = id }
  deinit { print(id) }
}
struct Wrap<T> {
  var v: T
  var n: Int
}
enum Maybe<T> {
  case some(T)
  case none
}
func unwrapOr(_ m: Maybe<(Int) -> Int>, _ x: Int) -> Int {
  switch m {
  case .some(let f): return f(x)
  case .none: return x
  }
}
func scope1() {
  let t = Tag(id: 1)
  let w: Wrap<(Int) -> Int> = Wrap<(Int) -> Int>(v: { $0 + t.id }, n: 3)
  print(w.v(10) + w.n)
}
scope1()
print(2)
func scope2() {
  let t = Tag(id: 3)
  let m: Maybe<(Int) -> Int> = Maybe<(Int) -> Int>.some({ $0 * t.id })
  print(unwrapOr(m, 5))
}
scope2()
print(4)
let plain: Wrap<(Int) -> Int> = Wrap<(Int) -> Int>(v: { $0 - 1 }, n: 8)
print(plain.v(10) + plain.n)
print(unwrapOr(.none, 6))
