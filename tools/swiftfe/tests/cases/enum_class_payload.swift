class Node {
  let id: Int
  deinit {
    print(self.id)
  }
}
enum Slot {
  case empty
  case full(Node)
  case pair(Int, Node)
}
func describe(_ s: Slot) -> Int {
  switch s {
  case .empty:
    return 0
  case .full(let n):
    return n.id
  case .pair(let k, let n):
    return k + n.id
  }
}
func demo() {
  let a = Slot.full(Node(id: 1))
  let b: Slot = .pair(10, Node(id: 2))
  print(describe(a))
  print(describe(b))
  print(describe(.empty))
  let c = Slot.full(Node(id: 3))
  print(describe(c))
}
demo()
print(0)
