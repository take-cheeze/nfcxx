class Node {
  let id: Int
  deinit {
    print(self.id)
  }
}
enum Slot {
  case empty
  case full(Node)
}
class Holder {
  var slot: Slot
}
func holderDemo() {
  let h = Holder(slot: .full(Node(id: 9)))
  h.slot = .full(Node(id: 4))
  h.slot = .empty
  print(0)
}
holderDemo()
let maybe: Slot? = Slot.full(Node(id: 6))
if let s = maybe {
  switch s {
  case .full(let n):
    print(n.id)
  case .empty:
    print(-1)
  }
}
print(maybe == nil)
