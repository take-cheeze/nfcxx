func dbl(_ n: Int) -> Int { return n * 2 }
struct Op {
  var f: (Int) -> Int
  var g: (Int) -> Int
}
struct Pair {
  var op: Op
  var n: Int
}
enum Tr {
  case fn((Int) -> Int)
  case none
}
func run(_ t: Tr, _ x: Int) -> Int {
  switch t {
  case .fn(let f): return f(x)
  case .none: return x
  }
}
func build(_ k: Int) -> Op {
  return Op(f: { $0 + k }, g: dbl)
}
let o = Op(f: dbl, g: { $0 + 1 })
print(o.f(3))
print(o.g(3))
print(run(.fn(dbl), 5))
let p = Pair(op: build(10), n: 4)
print(p.op.f(p.n))
print(p.op.g(1))
let q = Pair(op: o, n: 1)
print(q.op.f(q.n))
print(run(Tr.fn({ $0 * 3 }), 4))
let kk = 5
print(run(.fn({ $0 + kk }), 4))
print(run(.none, 4))
let ops = [Pair(op: o, n: 1)]
print(ops.count)
