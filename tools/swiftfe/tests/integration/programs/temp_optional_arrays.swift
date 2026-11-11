class Node {
  let id: Int
  init(id: Int) {
    self.id = id
  }
  deinit {
    print(self.id + 300)
  }
}

func make(_ n: Int) -> [Int] {
  var out: [Int] = []
  for i in 0..<n {
    out.append(i * 10)
  }
  return out
}

func makeNodes(_ n: Int) -> [Node] {
  var out: [Node] = []
  for i in 0..<n {
    out.append(Node(id: i))
  }
  return out
}

func maybe(_ flag: Bool) -> [Int]? {
  if flag {
    return [1, 2]
  }
  return nil
}

struct Bag {
  var items: [Int]?
  var count: Int
}

func demo() {
  print(make(3)[1])
  print(make(4).count)
  var opt: [Int]? = nil
  print(opt == nil)
  opt = [5, 6]
  print(opt!.count)
  print(opt![1])
  if let xs = opt {
    print(xs.count)
  }
  let copy = opt
  opt = nil
  print(copy!.count)
  let m = maybe(true)
  print(m == nil)
  if let ys = m {
    print(ys[0])
  }
  let none = maybe(false)
  print(none == nil)
  var arr = [[1, 2], [3]]
  print(arr[0].count)
  arr[1] = make(2)
  print(arr[1][1])
  print([1, 2, 3][2])
  print([7, 8].count)
  let node = makeNodes(2)[0]
  print(node.id)
  print(makeNodes(3).count)
  makeNodes(1)[0]
  var bag = Bag(items: [4], count: 1)
  bag.items = make(2)
  print(bag.count)
  print(bag.items!.count)
}
demo()
print(0)
