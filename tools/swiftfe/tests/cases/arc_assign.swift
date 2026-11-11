class Node {
  let id: Int
  var next: Node?
  deinit {
    print(self.id)
  }
}
func f() {
  let head = Node(id: 1, next: nil)
  head.next = Node(id: 2, next: nil)
  print(head.next == nil)
}
f()
print(0)
