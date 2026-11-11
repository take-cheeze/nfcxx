class Node {
  let id: Int
  init(id: Int) {
    self.id = id
  }
  deinit {
    print(self.id)
  }
}

func make(_ n: Int) -> [Node] {
  var out: [Node] = []
  for i in 0..<n {
    out.append(Node(id: i))
  }
  return out
}

func total(_ xs: [Node]) -> Int {
  var sum = 0
  for x in xs {
    sum = sum + x.id
  }
  return sum
}

var kept: [Node] = []

func demo() {
  let a = [Node(id: 1), Node(id: 2)]
  let b = a
  print(total(a) + total(b))
  var c = make(3)
  c[1] = Node(id: 10)
  print(c.count)
  print(c[1].id)
  let d = c
  c.append(Node(id: 20))
  print(d.count)
  print(c.count)
  kept = c
}
demo()
print(0)
