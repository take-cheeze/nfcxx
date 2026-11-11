final class Node {
  let id: Int
  init(id: Int) { self.id = id }
  deinit { print(id) }
}
func scoped() -> Int {
  let t = Node(id: 1)
  let f: () -> Int = { t.id }
  return f()
}
print(scoped())
print(0)
func run() {
  var cur = Node(id: 2)
  let show: () -> Int = { cur.id }
  print(show())
  cur = Node(id: 3)
  print(show())
}
run()
print(9)
func makeAcc(_ start: Int) -> () -> Int {
  var total = start
  return {
    let step: () -> Int = { total = total + 1; return total }
    return step()
  }
}
let acc = makeAcc(10)
print(acc())
print(acc())
func makeAdder(_ k: Int) -> (Int) -> Int {
  return { $0 + k }
}
print(makeAdder(2)(5))
var op: (Int) -> Int = { $0 * 100 }
print(op(1))
let k = 7
op = { $0 - k }
print(op(1))
