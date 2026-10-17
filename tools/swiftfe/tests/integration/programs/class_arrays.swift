class Node {
  let id: Int
  init(id: Int) {
    self.id = id
  }
  deinit {
    print(self.id + 100)
  }
}

enum Slot {
  case empty
  case full(Node)
}

func pick(_ n: Int) -> Int {
  print(n + 200)
  return n
}

func demo() {
  var slots: [Slot] = [.empty, Slot.full(Node(id: 1))]
  slots.append(.full(Node(id: 2)))
  let copy = slots
  slots[0] = Slot.full(Node(id: 3))
  for s in copy {
    switch s {
    case .empty:
      print(0)
    case .full(let n):
      print(n.id)
    }
  }
  var opts: [Node?] = [nil, Node(id: 4)]
  opts.append(nil)
  let keep = opts[1]
  opts[1] = nil
  print(keep == nil)
  var grid: [[Node]] = [[Node(id: 5)], []]
  grid[1].append(Node(id: 6))
  let rows = grid
  grid[0][0] = Node(id: 7)
  print(rows[0][0].id + grid[1][0].id)
  var items = [Node(id: 8), Node(id: 9)]
  items[pick(1)] = Node(id: 10)
  items.append(items[0])
  print(items.count)
}
demo()
print(0)
