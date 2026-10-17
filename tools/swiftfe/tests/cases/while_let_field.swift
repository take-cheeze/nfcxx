class Node {
  let id: Int
  var next: Node?
  deinit {
    print(self.id)
  }
}
class Holder {
  var first: Node?
}
func drain(_ h: Holder) {
  while let n = h.first {
    print(n.id)
    h.first = n.next
  }
}
func build() {
  let h = Holder(first: nil)
  h.first = Node(id: 1, next: Node(id: 2, next: nil))
  drain(h)
  print(0)
}
build()
