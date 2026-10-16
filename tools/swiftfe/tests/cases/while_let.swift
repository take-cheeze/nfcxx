class Node {
  let id: Int
  var next: Node?
  deinit {
    print(self.id)
  }
}
func next(of node: Node) -> Node? {
  return node.next
}
func walk(_ start: Node?) {
  var cur = start
  while let n = cur {
    print(n.id)
    cur = n.next
  }
}
func firstBig(_ start: Node?) -> Int {
  var cur = start
  while let n = cur {
    if n.id > 1 {
      return n.id
    }
    cur = n.next
  }
  return 0
}
func step(_ n: Int) -> Int? {
  if n > 0 {
    return n - 1
  }
  return nil
}
func countDown(_ start: Int) {
  var n = start
  while let v = step(n) {
    print(v)
    n = v
  }
}
func scoped() {
  let a = Node(id: 10, next: Node(id: 20, next: Node(id: 30, next: nil)))
  walk(a)
  print(firstBig(a))
  var k: Node? = next(of: a)
  while let m = k {
    print(m.id * 10)
    k = next(of: m)
  }
}
var x: Int? = 3
while let v = x {
  print(v)
  if v == 1 {
    x = nil
  } else {
    x = v - 1
  }
}
countDown(3)
scoped()
print(0)
