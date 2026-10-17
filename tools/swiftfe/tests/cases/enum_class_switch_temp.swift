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
func early(_ flag: Bool) -> Int {
  switch Slot.pair(7, Node(id: 8)) {
  case .pair(let k, let n):
    if flag {
      return k + n.id
    }
    return 0
  default:
    return -1
  }
}
switch Slot.full(Node(id: 5)) {
case .full(let n):
  print(n.id)
case .empty:
  print(0)
case .pair(let k, let n):
  print(k + n.id)
}
print(early(true))
print(early(false))
print(0)
