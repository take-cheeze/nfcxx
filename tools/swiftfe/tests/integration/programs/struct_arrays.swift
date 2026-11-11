class Node {
  let id: Int
  init(id: Int) {
    self.id = id
  }
  deinit {
    print(self.id + 100)
  }
}

struct Bag {
  var items: [Int]
  var nodes: [Node]
}

struct Pair {
  var first: Bag
  var tag: Int
}

enum Holder {
  case empty
  case list([Int])
}

struct Wrap {
  var h: Holder
}

func total(_ b: Bag) -> Int {
  var sum = 0
  for x in b.items {
    sum = sum + x
  }
  return sum + b.nodes.count
}

func make(_ n: Int) -> Bag {
  var b = Bag(items: [], nodes: [])
  for i in 0..<n {
    b.items.append(i)
    b.nodes.append(Node(id: i))
  }
  return b
}

var global = Bag(items: [7], nodes: [])

func demo() {
  var a = make(3)
  let b = a
  a.items[0] = 50
  a.nodes[1] = Node(id: 9)
  print(total(a))
  print(total(b))
  a.items.append(4)
  print(a.items.count)
  print(b.items.count)
  var p = Pair(first: b, tag: 1)
  p.first.items.append(8)
  print(p.first.items.count)
  print(b.items.count)
  let q = p
  p.first = a
  print(q.first.items.count)
  var w = Wrap(h: .list([1, 2]))
  let w2 = w
  w = Wrap(h: .empty)
  switch w2.h {
  case .empty:
    print(0)
  case .list(let xs):
    print(xs.count)
  }
  global.items.append(2)
  print(global.items.count)
}
demo()
print(0)
