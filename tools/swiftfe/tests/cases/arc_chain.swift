class Node {
  let id: Int
  var next: Node?
  deinit {
    print(self.id)
  }
}
func build() {
  let a = Node(id: 1, next: nil)
  let b = Node(id: 2, next: a)
  print(b.id)
}
build()
print(0)
